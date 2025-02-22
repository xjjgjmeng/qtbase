// Copyright (C) 2016 The Qt Company Ltd.
// Copyright (c) 2007-2008, Apple, Inc.
// SPDX-License-Identifier: BSD-3-Clause

#include <AppKit/AppKit.h>

#include "qcocoaeventdispatcher.h"
#include "qcocoawindow.h"
#include "qcocoahelpers.h"

#include <QtGui/qevent.h>
#include <QtGui/qguiapplication.h>
#include <QtGui/private/qguiapplication_p.h>

#include <QtCore/qmutex.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qsocketnotifier.h>
#include <QtCore/private/qthread_p.h>
#include <QtCore/private/qcore_mac_p.h>

#include <qpa/qplatformwindow.h>
#include <qpa/qplatformnativeinterface.h>

#include <QtCore/qdebug.h>

QT_BEGIN_NAMESPACE

Q_LOGGING_CATEGORY(lcEventDispatcher, "qt.eventdispatcher");

static inline CFRunLoopRef mainRunLoop()
{
    return CFRunLoopGetMain();
}

static Boolean runLoopSourceEqualCallback(const void *info1, const void *info2)
{
    return info1 == info2;
}

/*****************************************************************************
  Timers stuff
 *****************************************************************************/

/* timer call back */
void QCocoaEventDispatcherPrivate::runLoopTimerCallback(CFRunLoopTimerRef, void *info)
{
    QCocoaEventDispatcherPrivate *d = static_cast<QCocoaEventDispatcherPrivate *>(info);
    if (d->processEventsCalled && (d->processEventsFlags & QEventLoop::EventLoopExec) == 0) {
        // processEvents() was called "manually," ignore this source for now
        d->maybeCancelWaitForMoreEvents();
        return;
    }
    CFRunLoopSourceSignal(d->activateTimersSourceRef);
}

void QCocoaEventDispatcherPrivate::activateTimersSourceCallback(void *info)
{
    QCocoaEventDispatcherPrivate *d = static_cast<QCocoaEventDispatcherPrivate *>(info);
    if (d->initializingNSApplication) {
        qCDebug(lcEventDispatcher) << "Deferring" << __FUNCTION__ << "due to NSApp initialization";
        // We don't want to process any sources during explicit NSApplication
        // initialization, so defer the source until the actual event processing.
        CFRunLoopSourceSignal(d->activateTimersSourceRef);
        return;
    }
    d->processTimers();
    d->maybeCancelWaitForMoreEvents();
}

bool QCocoaEventDispatcherPrivate::processTimers()
{
    int activated = timerInfoList.activateTimers();
    maybeStartCFRunLoopTimer();
    return activated > 0;
}

void QCocoaEventDispatcherPrivate::maybeStartCFRunLoopTimer()
{
    if (timerInfoList.isEmpty()) {
        // no active timers, so the CFRunLoopTimerRef should not be active either
        Q_ASSERT(!runLoopTimerRef);
        return;
    }

    using DoubleSeconds = std::chrono::duration<double, std::ratio<1>>;
    if (!runLoopTimerRef) {
        // start the CFRunLoopTimer
        CFAbsoluteTime ttf = CFAbsoluteTimeGetCurrent();
        CFTimeInterval interval;
        CFTimeInterval oneyear = CFTimeInterval(3600. * 24. * 365.);

        // Q: when should the CFRunLoopTimer fire for the first time?
        if (auto opt = timerInfoList.timerWait()) {
            // A: when we have timers to fire, of course
            DoubleSeconds secs{*opt};
            interval = qMax(secs.count(), 0.0000001);
        } else {
            // this shouldn't really happen, but in case it does, set the timer to fire a some point in the distant future
            interval = oneyear;
        }

        ttf += interval;
        CFRunLoopTimerContext info = { 0, this, nullptr, nullptr, nullptr };
        // create the timer with a large interval, as recommended by the CFRunLoopTimerSetNextFireDate()
        // documentation, since we will adjust the timer's time-to-fire as needed to keep Qt timers working
        runLoopTimerRef = CFRunLoopTimerCreate(nullptr, ttf, oneyear, 0, 0, QCocoaEventDispatcherPrivate::runLoopTimerCallback, &info);
        Q_ASSERT(runLoopTimerRef);

        CFRunLoopAddTimer(mainRunLoop(), runLoopTimerRef, kCFRunLoopCommonModes);
    } else {
        // calculate when we need to wake up to process timers again
        CFAbsoluteTime ttf = CFAbsoluteTimeGetCurrent();
        CFTimeInterval interval;

        // Q: when should the timer first next?
        if (auto opt = timerInfoList.timerWait()) {
            // A: when we have timers to fire, of course
            DoubleSeconds secs{*opt};
            interval = qMax(secs.count(), 0.0000001);
        } else {
            // no timers can fire, but we cannot stop the CFRunLoopTimer, set the timer to fire at some
            // point in the distant future (the timer interval is one year)
            interval = CFRunLoopTimerGetInterval(runLoopTimerRef);
        }

        ttf += interval;
        CFRunLoopTimerSetNextFireDate(runLoopTimerRef, ttf);
    }
}

void QCocoaEventDispatcherPrivate::maybeStopCFRunLoopTimer()
{
    if (!runLoopTimerRef)
        return;

    CFRunLoopTimerInvalidate(runLoopTimerRef);
    CFRelease(runLoopTimerRef);
    runLoopTimerRef = nullptr;
}

void QCocoaEventDispatcher::registerTimer(Qt::TimerId timerId, Duration interval,
                                          Qt::TimerType timerType, QObject *obj)
{
#ifndef QT_NO_DEBUG
    if (qToUnderlying(timerId) < 1 || interval.count() < 0 || !obj) {
        qWarning("QCocoaEventDispatcher::registerTimer: invalid arguments");
        return;
    } else if (obj->thread() != thread() || thread() != QThread::currentThread()) {
        qWarning("QObject::startTimer: timers cannot be started from another thread");
        return;
    }
#endif

    Q_D(QCocoaEventDispatcher);
    d->timerInfoList.registerTimer(timerId, interval, timerType, obj);
    d->maybeStartCFRunLoopTimer();
}

bool QCocoaEventDispatcher::unregisterTimer(Qt::TimerId timerId)
{
#ifndef QT_NO_DEBUG
    if (qToUnderlying(timerId) < 1) {
        qWarning("QCocoaEventDispatcher::unregisterTimer: invalid argument");
        return false;
    } else if (thread() != QThread::currentThread()) {
        qWarning("QObject::killTimer: timers cannot be stopped from another thread");
        return false;
    }
#endif

    Q_D(QCocoaEventDispatcher);
    bool returnValue = d->timerInfoList.unregisterTimer(timerId);
    if (!d->timerInfoList.isEmpty())
        d->maybeStartCFRunLoopTimer();
    else
        d->maybeStopCFRunLoopTimer();
    return returnValue;
}

bool QCocoaEventDispatcher::unregisterTimers(QObject *obj)
{
#ifndef QT_NO_DEBUG
    if (!obj) {
        qWarning("QCocoaEventDispatcher::unregisterTimers: invalid argument");
        return false;
    } else if (obj->thread() != thread() || thread() != QThread::currentThread()) {
        qWarning("QObject::killTimers: timers cannot be stopped from another thread");
        return false;
    }
#endif

    Q_D(QCocoaEventDispatcher);
    bool returnValue = d->timerInfoList.unregisterTimers(obj);
    if (!d->timerInfoList.isEmpty())
        d->maybeStartCFRunLoopTimer();
    else
        d->maybeStopCFRunLoopTimer();
    return returnValue;
}

QList<QCocoaEventDispatcher::TimerInfoV2>
QCocoaEventDispatcher::timersForObject(QObject *object) const
{
#ifndef QT_NO_DEBUG
    if (!object) {
        qWarning("QCocoaEventDispatcher:registeredTimers: invalid argument");
        return {};
    }
#endif

    Q_D(const QCocoaEventDispatcher);
    return d->timerInfoList.registeredTimers(object);
}

/*
    Register a QSocketNotifier with the mac event system by creating a CFSocket with
    with a read/write callback.

    Qt has separate socket notifiers for reading and writing, but on the mac there is
    a limitation of one CFSocket object for each native socket.
*/
void QCocoaEventDispatcher::registerSocketNotifier(QSocketNotifier *notifier)
{
    Q_D(QCocoaEventDispatcher);
    d->cfSocketNotifier.registerSocketNotifier(notifier);
}

void QCocoaEventDispatcher::unregisterSocketNotifier(QSocketNotifier *notifier)
{
    Q_D(QCocoaEventDispatcher);
    d->cfSocketNotifier.unregisterSocketNotifier(notifier);
}

static bool isUserInputEvent(NSEvent* event)
{
    switch ([event type]) {
    case NSEventTypeLeftMouseDown:
    case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseDown:
    case NSEventTypeRightMouseUp:
    case NSEventTypeMouseMoved:                // ??
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeMouseEntered:
    case NSEventTypeMouseExited:
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp:
    case NSEventTypeFlagsChanged:            // key modifiers changed?
    case NSEventTypeCursorUpdate:            // ??
    case NSEventTypeScrollWheel:
    case NSEventTypeTabletPoint:
    case NSEventTypeTabletProximity:
    case NSEventTypeOtherMouseDown:
    case NSEventTypeOtherMouseUp:
    case NSEventTypeOtherMouseDragged:
#ifndef QT_NO_GESTURES
    case NSEventTypeGesture: // touch events
    case NSEventTypeMagnify:
    case NSEventTypeSwipe:
    case NSEventTypeRotate:
    case NSEventTypeBeginGesture:
    case NSEventTypeEndGesture:
#endif // QT_NO_GESTURES
        return true;
        break;
    default:
        break;
    }
    return false;
}

static inline void qt_mac_waitForMoreEvents(NSString *runLoopMode = NSDefaultRunLoopMode)
{
    // If no event exist in the cocoa event que, wait (and free up cpu time) until
    // at least one event occur. Setting 'dequeuing' to 'no' in the following call
    // causes it to hang under certain circumstances (QTBUG-28283), so we tell it
    // to dequeue instead, just to repost the event again:
    NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
        untilDate:[NSDate distantFuture]
        inMode:runLoopMode
        dequeue:YES];
    if (event)
        [NSApp postEvent:event atStart:YES];
}

bool QCocoaEventDispatcher::processEvents(QEventLoop::ProcessEventsFlags flags)
{
    Q_D(QCocoaEventDispatcher);

    // In rare rather corner cases a user's application messes with
    // QEventLoop::exec()/exit() and QCoreApplication::processEvents(),
    // we have to undo what bool blocker normally does.
    d->propagateInterrupt = false;
    const auto boolBlockerUndo = qScopeGuard([d](){
        if (d->propagateInterrupt)
            d->interrupt = true;
        d->propagateInterrupt = false;
    });
    QBoolBlocker interruptBlocker(d->interrupt, false);

    bool interruptLater = false;
    QtCocoaInterruptDispatcher::cancelInterruptLater();

    emit awake();

    uint oldflags = d->processEventsFlags;
    d->processEventsFlags = flags;

    // Used to determine whether any eventloop has been exec'ed, and allow posted
    // and timer events to be processed even if this function has never been called
    // instead of being kept on hold for the next run of processEvents().
    ++d->processEventsCalled;

    bool excludeUserEvents = d->processEventsFlags & QEventLoop::ExcludeUserInputEvents;
    bool retVal = false;
    forever {
        if (d->interrupt)
            break;

        QMacAutoReleasePool pool;
        NSEvent* event = nil;

        // First, send all previously excluded input events, if any:
        if (d->sendQueuedUserInputEvents())
            retVal = true;


        // If Qt is used as a plugin, or as an extension in a native cocoa
        // application, we should not run or stop NSApplication; This will be
        // done from the application itself. And if processEvents is called
        // manually (rather than from a QEventLoop), we cannot enter a tight
        // loop and block this call, but instead we need to return after one flush.
        // Finally, if we are to exclude user input events, we cannot call [NSApp run]
        // as we then loose control over which events gets dispatched:
        const bool canExec_3rdParty = d->nsAppRunCalledByQt || ![NSApp isRunning];
        const bool canExec_Qt = (!excludeUserEvents
                                 && ((d->processEventsFlags & QEventLoop::DialogExec)
                                     || (d->processEventsFlags & QEventLoop::EventLoopExec)));

        if (canExec_Qt && canExec_3rdParty) {
            // We can use exec-mode, meaning that we can stay in a tight loop until
            // interrupted. This is mostly an optimization, but it allow us to use
            // [NSApp run], which is the normal code path for cocoa applications.
            if (NSModalSession session = d->currentModalSession()) {
                QBoolBlocker execGuard(d->currentExecIsNSAppRun, false);
                qCDebug(lcEventDispatcher) << "Running modal session" << session;
                while ([NSApp runModalSession:session] == NSModalResponseContinue && !d->interrupt) {
                    qt_mac_waitForMoreEvents(NSModalPanelRunLoopMode);
                    if (session != d->currentModalSessionCached) {
                        // It's possible to release the current modal session
                        // while we are in this loop, for example, by closing all
                        // windows from a slot via QApplication::closeAllWindows.
                        // In this case we cannot use 'session' anymore. A warning
                        // from Cocoa is: "Use of freed session detected. Do not
                        // call runModalSession: after calling endModalSesion:."
                        break;
                    }
                }

                if (!d->interrupt && session == d->currentModalSessionCached) {
                    // Someone called [NSApp stopModal:] from outside the event
                    // dispatcher (e.g to stop a native dialog). But that call wrongly stopped
                    // 'session' as well. As a result, we need to restart all internal sessions:
                    d->temporarilyStopAllModalSessions();
                }

                // Clean up the modal session list, call endModalSession.
                if (d->cleanupModalSessionsNeeded)
                    d->cleanupModalSessions();

            } else {
                d->nsAppRunCalledByQt = true;
                QBoolBlocker execGuard(d->currentExecIsNSAppRun, true);
                [NSApp run];
            }
            retVal = true;
        } else {
            int lastSerialCopy = d->lastSerial;
            const bool hadModalSession = d->currentModalSessionCached;
            // We cannot block the thread (and run in a tight loop).
            // Instead we will process all current pending events and return.
            d->ensureNSAppInitialized();
            if (NSModalSession session = d->currentModalSession()) {
                // INVARIANT: a modal window is executing.
                if (!excludeUserEvents) {
                    // Since we can dispatch all kinds of events, we choose
                    // to use cocoa's native way of running modal sessions:
                    if (flags & QEventLoop::WaitForMoreEvents)
                        qt_mac_waitForMoreEvents(NSModalPanelRunLoopMode);
                    qCDebug(lcEventDispatcher) << "Running modal session" << session;
                    NSInteger status = [NSApp runModalSession:session];
                    if (status != NSModalResponseContinue && session == d->currentModalSessionCached) {
                        // INVARIANT: Someone called [NSApp stopModal:] from outside the event
                        // dispatcher (e.g to stop a native dialog). But that call wrongly stopped
                        // 'session' as well. As a result, we need to restart all internal sessions:
                        d->temporarilyStopAllModalSessions();
                    }

                    // Clean up the modal session list, call endModalSession.
                    if (d->cleanupModalSessionsNeeded)
                        d->cleanupModalSessions();

                    retVal = true;
                } else do {
                    // Dispatch all non-user events (but que non-user events up for later). In
                    // this case, we need more control over which events gets dispatched, and
                    // cannot use [NSApp runModalSession:session]:
                    event = [NSApp nextEventMatchingMask:NSEventMaskAny
                    untilDate:nil
                    inMode:NSModalPanelRunLoopMode
                    dequeue: YES];

                    if (event) {
                        if (isUserInputEvent(event)) {
                            [event retain];
                            d->queuedUserInputEvents.append(event);
                            continue;
                        }
                        if (!filterNativeEvent("NSEvent", event, nullptr)) {
                            [NSApp sendEvent:event];
                            retVal = true;
                        }
                    }
                } while (!d->interrupt && event);
            } else do {
                // INVARIANT: No modal window is executing.
                event = [NSApp nextEventMatchingMask:NSEventMaskAny
                untilDate:nil
                inMode:NSDefaultRunLoopMode
                dequeue: YES];

                if (event) {
                    if (flags & QEventLoop::ExcludeUserInputEvents) {
                        if (isUserInputEvent(event)) {
                            [event retain];
                            d->queuedUserInputEvents.append(event);
                            continue;
                        }
                    }
                    if (!filterNativeEvent("NSEvent", event, nullptr)) {
                        [NSApp sendEvent:event];
                        retVal = true;
                    }
                }

                // Clean up the modal session list, call endModalSession.
                if (d->cleanupModalSessionsNeeded)
                    d->cleanupModalSessions();

            } while (!d->interrupt && event);

            if ((d->processEventsFlags & QEventLoop::EventLoopExec) == 0) {
                // When called "manually", always process posted events and timers
                bool oldInterrupt = d->interrupt;
                d->processPostedEvents();
                if (!oldInterrupt && d->interrupt && !d->currentModalSession()) {
                    // We had direct processEvent call, coming not from QEventLoop::exec().
                    // One of the posted events triggered an application to interrupt the loop.
                    // But bool blocker will reset d->interrupt to false, so the real event
                    // loop will never notice it was interrupted. Now we'll have to fix it by
                    // enforcing the value of d->interrupt.
                    d->propagateInterrupt = true;
                }
                retVal = d->processTimers() || retVal;
            }

            // be sure to return true if the posted event source fired
            retVal = retVal || lastSerialCopy != d->lastSerial;

            // Since the window that holds modality might have changed while processing
            // events, we we need to interrupt when we return back the previous process
            // event recursion to ensure that we spin the correct modal session.
            // We do the interruptLater at the end of the function to ensure that we don't
            // disturb the 'wait for more events' below (as deleteLater will post an event):
            if (hadModalSession && !d->currentModalSessionCached)
                interruptLater = true;
        }
        bool canWait = (d->threadData.loadRelaxed()->canWait
                && !retVal
                && !d->interrupt
                && (d->processEventsFlags & QEventLoop::WaitForMoreEvents));
        if (canWait) {
            // INVARIANT: We haven't processed any events yet. And we're told
            // to stay inside this function until at least one event is processed.
            qt_mac_waitForMoreEvents();
            d->processEventsFlags &= ~QEventLoop::WaitForMoreEvents;
        } else {
            // Done with event processing for now.
            // Leave the function:
            break;
        }
    }

    d->processEventsFlags = oldflags;
    --d->processEventsCalled;

    // If we're interrupted, we need to interrupt the _current_
    // recursion as well to check if it is  still supposed to be
    // executing. This way we wind down the stack until we land
    // on a recursion that again calls processEvents (typically
    // from QEventLoop), and set interrupt to false:
    if (d->interrupt)
        interrupt();

    if (interruptLater)
        QtCocoaInterruptDispatcher::interruptLater();

    return retVal;
}

auto QCocoaEventDispatcher::remainingTime(Qt::TimerId timerId) const -> Duration
{
#ifndef QT_NO_DEBUG
    if (qToUnderlying(timerId) < 1) {
        qWarning("QCocoaEventDispatcher::remainingTime: invalid argument");
        return Duration::min();
    }
#endif

    Q_D(const QCocoaEventDispatcher);
    return d->timerInfoList.remainingDuration(timerId);
}

void QCocoaEventDispatcher::wakeUp()
{
    Q_D(QCocoaEventDispatcher);
    d->serialNumber.ref();
    CFRunLoopSourceSignal(d->postedEventsSource);
    CFRunLoopWakeUp(mainRunLoop());
}

/*****************************************************************************
  QEventDispatcherMac Implementation
 *****************************************************************************/

void QCocoaEventDispatcherPrivate::ensureNSAppInitialized()
{
    // Some elements in Cocoa require NSApplication to be initialized before
    // use, for example the menu bar. Under normal circumstances this happens
    // as part of [NSApp run], as a result of a call to QGuiApplication:exec(),
    // but in the cases where a dialog is asked to execute before that happens,
    // or the application spins the event loop manually via processEvents(),
    // we need to explicitly ensure NSApplication initialization.

    // We can unfortunately not do this via NSApplicationLoad(), as the function
    // bails out early if there's already an NSApplication instance, which is
    // the case if any code has called [NSApplication sharedApplication],
    // or its short form 'NSApp'.

    // Instead we do an actual [NSApp run], but stop the application as soon
    // as possible, ensuring that AppKit will do the required initialization,
    // including calling [NSApplication finishLaunching].

    // We only apply this trick at most once for any application, and we avoid
    // doing it for the common case where main just starts QGuiApplication::exec.
    if (nsAppRunCalledByQt || [NSApp isRunning])
        return;

    qCDebug(lcEventDispatcher) << "Ensuring NSApplication is initialized";
    nsAppRunCalledByQt = true;

    // Stopping the application will still process runloop sources before
    // actually stopping, so we need to explicitly guard our sources from
    // doing anything, deferring their actions until later.
    QBoolBlocker initializationGuard(initializingNSApplication, true);

    CFRunLoopPerformBlock(mainRunLoop(), kCFRunLoopCommonModes, ^{
        qCDebug(lcEventDispatcher) << "NSApplication has been initialized; Stopping NSApp";
        [NSApp stop:NSApp];
        cancelWaitForMoreEvents(); // Post event that wakes up the runloop
    });
    [NSApp run];
    qCDebug(lcEventDispatcher) << "Finished ensuring NSApplication is initialized";
}

void QCocoaEventDispatcherPrivate::temporarilyStopAllModalSessions()
{
    // Flush, and Stop, all created modal session, and as
    // such, make them pending again. The next call to
    // currentModalSession will recreate them again. The
    // reason to stop all session like this is that otherwise
    // a call [NSApp stop] would not stop NSApp, but rather
    // the current modal session. So if we need to stop NSApp
    // we need to stop all the modal session first. To avoid changing
    // the stacking order of the windows while doing so, we put
    // up a block that is used in QCocoaWindow and QCocoaPanel:
    int stackSize = cocoaModalSessionStack.size();
    for (int i=0; i<stackSize; ++i) {
        QCocoaModalSessionInfo &info = cocoaModalSessionStack[i];
        if (info.session) {
            qCDebug(lcEventDispatcher) << "Temporarily ending modal session" << info.session
                                       << "for" << info.nswindow;
            [NSApp endModalSession:info.session];
            info.session = nullptr;
            [(NSWindow*) info.nswindow release];
        }
    }
    currentModalSessionCached = nullptr;
}

NSModalSession QCocoaEventDispatcherPrivate::currentModalSession()
{
    // If we have one or more modal windows, this function will create
    // a session for each of those, and return the one for the top.
    if (currentModalSessionCached)
        return currentModalSessionCached;

    if (cocoaModalSessionStack.isEmpty())
        return nullptr;

    int sessionCount = cocoaModalSessionStack.size();
    for (int i=0; i<sessionCount; ++i) {
        QCocoaModalSessionInfo &info = cocoaModalSessionStack[i];
        if (!info.window)
            continue;

        if (!info.session) {
            QMacAutoReleasePool pool;
            QCocoaWindow *cocoaWindow = static_cast<QCocoaWindow *>(info.window->handle());
            if (!cocoaWindow)
                continue;
            NSWindow *nswindow = cocoaWindow->nativeWindow();
            if (!nswindow)
                continue;

            ensureNSAppInitialized();
            QBoolBlocker block1(blockSendPostedEvents, true);
            info.nswindow = nswindow;
            [(NSWindow*) info.nswindow retain];
            QRect rect = cocoaWindow->geometry();
            info.session = [NSApp beginModalSessionForWindow:nswindow];
            qCDebug(lcEventDispatcher) << "Begun modal session" << info.session
                                       << "for" << nswindow;

            // The call to beginModalSessionForWindow above processes events and may
            // have deleted or destroyed the window. Check if it's still valid.
            if (!info.window)
                continue;
            cocoaWindow = static_cast<QCocoaWindow *>(info.window->handle());
            if (!cocoaWindow)
                continue;

            if (rect != cocoaWindow->geometry())
                cocoaWindow->setGeometry(rect);
        }
        currentModalSessionCached = info.session;
        cleanupModalSessionsNeeded = false;
    }
    return currentModalSessionCached;
}

bool QCocoaEventDispatcherPrivate::hasModalSession() const
{
    return !cocoaModalSessionStack.isEmpty();
}

void QCocoaEventDispatcherPrivate::cleanupModalSessions()
{
    // Go through the list of modal sessions, and end those
    // that no longer has a window associated; no window means
    // the session has logically ended. The reason we wait like
    // this to actually end the sessions for real (rather than at the
    // point they were marked as stopped), is that ending a session
    // when no other session runs below it on the stack will make cocoa
    // drop some events on the floor.
    QMacAutoReleasePool pool;
    int stackSize = cocoaModalSessionStack.size();

    for (int i=stackSize-1; i>=0; --i) {
        QCocoaModalSessionInfo &info = cocoaModalSessionStack[i];
        if (info.window) {
            // This session has a window, and is therefore not marked
            // as stopped. So just make it current. There might still be other
            // stopped sessions on the stack, but those will be stopped on
            // a later "cleanup" call.
            currentModalSessionCached = info.session;
            break;
        }
        currentModalSessionCached = nullptr;
        if (info.session) {
            Q_ASSERT(info.nswindow);
            qCDebug(lcEventDispatcher) << "Ending modal session" << info.session
                                       << "for" << info.nswindow;
            [NSApp endModalSession:info.session];
            [(NSWindow *)info.nswindow release];
        }
        // remove the info now that we are finished with it
        cocoaModalSessionStack.remove(i);
    }

    cleanupModalSessionsNeeded = false;
}

void QCocoaEventDispatcherPrivate::beginModalSession(QWindow *window)
{
    qCDebug(lcEventDispatcher) << "Adding modal session for" << window;

    if (std::any_of(cocoaModalSessionStack.constBegin(), cocoaModalSessionStack.constEnd(),
        [&](const auto &sessionInfo) { return sessionInfo.window == window; })) {
        qCWarning(lcEventDispatcher) << "Modal session for" << window << "already exists!";
        return;
    }

    // We need to start spinning the modal session. Usually this is done with
    // QDialog::exec() for Qt Widgets based applications, but for others that
    // just call show(), we need to interrupt().
    Q_Q(QCocoaEventDispatcher);
    q->interrupt();

    // Add a new, empty (null), NSModalSession to the stack.
    // It will become active the next time QEventDispatcher::processEvents is called.
    // A QCocoaModalSessionInfo is considered pending to become active if the window pointer
    // is non-zero, and the session pointer is zero (it will become active upon a call to
    // currentModalSession). A QCocoaModalSessionInfo is considered pending to be stopped if
    // the window pointer is zero, and the session pointer is non-zero (it will be fully
    // stopped in cleanupModalSessions()).
    QCocoaModalSessionInfo info = {window, nullptr, nullptr};
    cocoaModalSessionStack.push(info);
    currentModalSessionCached = nullptr;
}

void QCocoaEventDispatcherPrivate::endModalSession(QWindow *window)
{
    qCDebug(lcEventDispatcher) << "Removing modal session for" << window;

    Q_Q(QCocoaEventDispatcher);

    // Mark all sessions attached to window as pending to be stopped. We do this
    // by setting the window pointer to zero, but leave the session pointer.
    // We don't tell cocoa to stop any sessions just yet, because cocoa only understands
    // when we stop the _current_ modal session (which is the session on top of
    // the stack, and might not belong to 'window').
    int stackSize = cocoaModalSessionStack.size();
    int endedSessions = 0;
    for (int i=stackSize-1; i>=0; --i) {
        QCocoaModalSessionInfo &info = cocoaModalSessionStack[i];
        if (!info.window)
            endedSessions++;
        if (info.window == window) {
            info.window = nullptr;
            if (i + endedSessions == stackSize-1) {
                // The top sessions ended. Interrupt the event dispatcher to
                // start spinning the correct session immediately.
                q->interrupt();
                currentModalSessionCached = nullptr;
                cleanupModalSessionsNeeded = true;
            }
        }
    }
}

QCocoaEventDispatcherPrivate::QCocoaEventDispatcherPrivate()
    : processEventsFlags(0),
      runLoopTimerRef(nullptr),
      blockSendPostedEvents(false),
      currentExecIsNSAppRun(false),
      nsAppRunCalledByQt(false),
      cleanupModalSessionsNeeded(false),
      processEventsCalled(0),
      currentModalSessionCached(nullptr),
      lastSerial(-1),
      interrupt(false)
{
}

void qt_mac_maybeCancelWaitForMoreEventsForwarder(QAbstractEventDispatcher *eventDispatcher)
{
    static_cast<QCocoaEventDispatcher *>(eventDispatcher)->d_func()->maybeCancelWaitForMoreEvents();
}

QCocoaEventDispatcher::QCocoaEventDispatcher(QObject *parent)
    : QAbstractEventDispatcherV2(*new QCocoaEventDispatcherPrivate, parent)
{
    Q_D(QCocoaEventDispatcher);

    d->cfSocketNotifier.setHostEventDispatcher(this);
    d->cfSocketNotifier.setMaybeCancelWaitForMoreEventsCallback(qt_mac_maybeCancelWaitForMoreEventsForwarder);

    // keep our sources running when modal loops are running
    CFRunLoopAddCommonMode(mainRunLoop(), (CFStringRef) NSModalPanelRunLoopMode);

    CFRunLoopSourceContext context;
    bzero(&context, sizeof(CFRunLoopSourceContext));
    context.info = d;
    context.equal = runLoopSourceEqualCallback;

    // source used to activate timers
    context.perform = QCocoaEventDispatcherPrivate::activateTimersSourceCallback;
    d->activateTimersSourceRef = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
    Q_ASSERT(d->activateTimersSourceRef);
    CFRunLoopAddSource(mainRunLoop(), d->activateTimersSourceRef, kCFRunLoopCommonModes);

    // source used to send posted events
    context.perform = QCocoaEventDispatcherPrivate::postedEventsSourceCallback;
    d->postedEventsSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
    Q_ASSERT(d->postedEventsSource);
    CFRunLoopAddSource(mainRunLoop(), d->postedEventsSource, kCFRunLoopCommonModes);

    // observer to emit aboutToBlock() and awake()
    CFRunLoopObserverContext observerContext;
    bzero(&observerContext, sizeof(CFRunLoopObserverContext));
    observerContext.info = this;
    d->waitingObserver = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                                 kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting,
                                                 true, 0,
                                                 QCocoaEventDispatcherPrivate::waitingObserverCallback,
                                                 &observerContext);
    CFRunLoopAddObserver(mainRunLoop(), d->waitingObserver, kCFRunLoopCommonModes);
}

void QCocoaEventDispatcherPrivate::waitingObserverCallback(CFRunLoopObserverRef,
                                                          CFRunLoopActivity activity, void *info)
{
    if (activity == kCFRunLoopBeforeWaiting)
        emit static_cast<QCocoaEventDispatcher*>(info)->aboutToBlock();
    else
        emit static_cast<QCocoaEventDispatcher*>(info)->awake();
}

bool QCocoaEventDispatcherPrivate::sendQueuedUserInputEvents()
{
    Q_Q(QCocoaEventDispatcher);
    if (processEventsFlags & QEventLoop::ExcludeUserInputEvents)
        return false;
    bool didSendEvent = false;
    while (!queuedUserInputEvents.isEmpty()) {
        NSEvent *event = static_cast<NSEvent *>(queuedUserInputEvents.takeFirst());
        if (!q->filterNativeEvent("NSEvent", event, nullptr)) {
            [NSApp sendEvent:event];
            didSendEvent = true;
        }
        [event release];
    }
    return didSendEvent;
}

void QCocoaEventDispatcherPrivate::processPostedEvents()
{
    if (blockSendPostedEvents) {
        // We're told to not send posted events (because the event dispatcher
        // is currently working on setting up the correct session to run). But
        // we still need to make sure that we don't fall asleep until pending events
        // are sendt, so we just signal this need, and return:
        CFRunLoopSourceSignal(postedEventsSource);
        return;
    }

    if (cleanupModalSessionsNeeded && currentExecIsNSAppRun)
        cleanupModalSessions();

    if (processEventsCalled > 0 && interrupt) {
        if (currentExecIsNSAppRun) {
            // The event dispatcher has been interrupted. But since
            // [NSApplication run] is running the event loop, we
            // delayed stopping it until now (to let cocoa process
            // pending cocoa events first).
            if (currentModalSessionCached)
                temporarilyStopAllModalSessions();
            [NSApp stop:NSApp];
            cancelWaitForMoreEvents();
        }
        return;
    }

    int serial = serialNumber.loadRelaxed();
    if (!threadData.loadRelaxed()->canWait || (serial != lastSerial)) {
        lastSerial = serial;
        QCoreApplication::sendPostedEvents();
        QWindowSystemInterface::sendWindowSystemEvents(QEventLoop::AllEvents);
    }
}

void QCocoaEventDispatcherPrivate::postedEventsSourceCallback(void *info)
{
    QCocoaEventDispatcherPrivate *d = static_cast<QCocoaEventDispatcherPrivate *>(info);
    if (d->initializingNSApplication) {
        qCDebug(lcEventDispatcher) << "Deferring" << __FUNCTION__ << "due to NSApp initialization";
        // We don't want to process any sources during explicit NSApplication
        // initialization, so defer the source until the actual event processing.
        CFRunLoopSourceSignal(d->postedEventsSource);
        return;
    }

    if (d->processEventsCalled && (d->processEventsFlags & QEventLoop::EventLoopExec) == 0) {
        // processEvents() was called "manually," ignore this source for now
        d->maybeCancelWaitForMoreEvents();
        return;
    }
    d->sendQueuedUserInputEvents();
    d->processPostedEvents();
    d->maybeCancelWaitForMoreEvents();
}

void QCocoaEventDispatcherPrivate::cancelWaitForMoreEvents()
{
    // In case the event dispatcher is waiting for more
    // events somewhere, we post a dummy event to wake it up:
    QMacAutoReleasePool pool;
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
        modifierFlags:0 timestamp:0. windowNumber:0 context:nil
        subtype:QtCocoaEventSubTypeWakeup data1:0 data2:0] atStart:NO];
}

void QCocoaEventDispatcherPrivate::maybeCancelWaitForMoreEvents()
{
    if ((processEventsFlags & (QEventLoop::EventLoopExec | QEventLoop::WaitForMoreEvents)) == QEventLoop::WaitForMoreEvents) {
        // RunLoop sources are not NSEvents, but they do generate Qt events. If
        // WaitForMoreEvents was set, but EventLoopExec is not, processEvents()
        // should return after a source has sent some Qt events.
        cancelWaitForMoreEvents();
    }
}

void QCocoaEventDispatcher::interrupt()
{
    Q_D(QCocoaEventDispatcher);
    d->interrupt = true;
    wakeUp();

    // We do nothing more here than setting d->interrupt = true, and
    // poke the event loop if it is sleeping. Actually stopping
    // NSApp, or the current modal session, is done inside the send
    // posted events callback. We do this to ensure that all current pending
    // cocoa events gets delivered before we stop. Otherwise, if we now stop
    // the last event loop recursion, cocoa will just drop pending posted
    // events on the floor before we get a chance to reestablish a new session.
    d->cancelWaitForMoreEvents();
}

// QTBUG-56746: The behavior of processEvents() has been changed to not clear
// the interrupt flag. Use this function to clear it.
 void QCocoaEventDispatcher::clearCurrentThreadCocoaEventDispatcherInterruptFlag()
{
    QCocoaEventDispatcher *cocoaEventDispatcher =
            qobject_cast<QCocoaEventDispatcher *>(QThread::currentThread()->eventDispatcher());
    if (!cocoaEventDispatcher)
        return;
    QCocoaEventDispatcherPrivate *cocoaEventDispatcherPrivate =
            static_cast<QCocoaEventDispatcherPrivate *>(QObjectPrivate::get(cocoaEventDispatcher));
    cocoaEventDispatcherPrivate->interrupt = false;
}

QCocoaEventDispatcher::~QCocoaEventDispatcher()
{
    Q_D(QCocoaEventDispatcher);

    d->timerInfoList.clearTimers();
    d->maybeStopCFRunLoopTimer();
    CFRunLoopRemoveSource(mainRunLoop(), d->activateTimersSourceRef, kCFRunLoopCommonModes);
    CFRelease(d->activateTimersSourceRef);

    // end all modal sessions
    for (int i = 0; i < d->cocoaModalSessionStack.count(); ++i) {
        QCocoaModalSessionInfo &info = d->cocoaModalSessionStack[i];
        if (info.session) {
            qCDebug(lcEventDispatcher) << "Ending modal session" << info.session
                                       << "for" << info.nswindow << "during shutdown";
            [NSApp endModalSession:info.session];
            [(NSWindow *)info.nswindow release];
        }
    }

    // release all queued user input events
    for (int i = 0; i < d->queuedUserInputEvents.count(); ++i) {
        NSEvent *nsevent = static_cast<NSEvent *>(d->queuedUserInputEvents.at(i));
        [nsevent release];
    }

    d->cfSocketNotifier.removeSocketNotifiers();

    CFRunLoopRemoveSource(mainRunLoop(), d->postedEventsSource, kCFRunLoopCommonModes);
    CFRelease(d->postedEventsSource);

    CFRunLoopObserverInvalidate(d->waitingObserver);
    CFRelease(d->waitingObserver);
}

QtCocoaInterruptDispatcher* QtCocoaInterruptDispatcher::instance = nullptr;

QtCocoaInterruptDispatcher::QtCocoaInterruptDispatcher() : cancelled(false)
{
    // The whole point of this class is that we enable a way to interrupt
    // the event dispatcher when returning back to a lower recursion level
    // than where interruptLater was called. This is needed to detect if
    // [NSApp run] should still be running at the recursion level it is at.
    // Since the interrupt is canceled if processEvents is called before
    // this object gets deleted, we also avoid interrupting unnecessary.
    deleteLater();
}

QtCocoaInterruptDispatcher::~QtCocoaInterruptDispatcher()
{
    if (cancelled)
        return;
    instance = nullptr;
    QCocoaEventDispatcher::instance()->interrupt();
}

void QtCocoaInterruptDispatcher::cancelInterruptLater()
{
    if (!instance)
        return;
    instance->cancelled = true;
    delete instance;
    instance = nullptr;
}

void QtCocoaInterruptDispatcher::interruptLater()
{
    cancelInterruptLater();
    instance = new QtCocoaInterruptDispatcher;
}

QT_END_NAMESPACE

