//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Minimal `UIWindowSceneDelegate` required by iOS 27+, which no longer launches
/// apps that don't adopt the scene lifecycle (see Apple TN3187).
///
/// Signal's actual window/UI setup remains entirely owned by `AppDelegate`, which
/// still runs first (`application(_:didFinishLaunchingWithOptions:)`) and creates
/// `AppDelegate.window` before this delegate is ever invoked. This shim hands that
/// already-created window the `UIWindowScene` the system provides, and forwards the
/// callbacks UIKit stops delivering to `AppDelegate` once a scene manifest exists,
/// so nothing about Signal's launch/lifecycle sequencing changes.
///
/// `UIApplicationSupportsMultipleScenes` is `false`, so there is exactly one scene
/// and the forwarding below is 1:1 with the app-level callbacks it replaces.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    private var appDelegate: AppDelegate? {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            owsFailDebug("Unexpected application delegate type.")
            return nil
        }
        return appDelegate
    }

    // MARK: - Scene Connection

    // The `@available` hack mirrors the one on the `AppDelegate` method this
    // forwards to: it isn't deprecated, but it references `INStartAudioCallIntent`
    // and `INStartVideoCallIntent`, which are, and this project builds with
    // `-warnings-as-errors`.
    @available(iOS, deprecated: 13.0)
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions,
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            owsFailDebug("Connected to a non-window scene.")
            return
        }
        guard let appDelegate else {
            return
        }
        // `AppDelegate.window` is created synchronously in `didFinishLaunchingWithOptions`,
        // which always runs before this method, so it should already exist here.
        appDelegate.window?.windowScene = windowScene

        // `WindowManager`'s other windows (call view, return-to-call, clock skew
        // block, screen block) are also constructed during that same synchronous
        // launch path, before this method runs — so they need the scene handed to
        // them explicitly too, or they're never eligible to be shown (e.g. the
        // call view window, which is how video/audio calls get presented).
        //
        // `sharedIfSet` because `AppDelegate` returns early without building the
        // environment when running tests or when launch fails.
        AppEnvironment.sharedIfSet?.windowManagerRef.windowSceneDidConnect(windowScene)

        // On a cold launch, UIKit delivers these here rather than through the
        // corresponding scene callbacks below.
        openUrls(in: connectionOptions.urlContexts)
        for userActivity in connectionOptions.userActivities {
            _ = appDelegate.application(.shared, continue: userActivity, restorationHandler: { _ in })
        }
        if let shortcutItem = connectionOptions.shortcutItem {
            appDelegate.application(.shared, performActionFor: shortcutItem, completionHandler: { _ in })
        }
    }

    // MARK: - Lifecycle

    // UIKit doesn't call the `UIApplicationDelegate` equivalents of these once the
    // app adopts scenes, so forward them to the implementations that still live there.

    func sceneWillEnterForeground(_ scene: UIScene) {
        appDelegate?.applicationWillEnterForeground(.shared)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        appDelegate?.applicationDidBecomeActive(.shared)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        appDelegate?.applicationWillResignActive(.shared)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        appDelegate?.applicationDidEnterBackground(.shared)
    }

    // MARK: - URL Handling

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        openUrls(in: URLContexts)
    }

    private func openUrls(in urlContexts: Set<UIOpenURLContext>) {
        guard let appDelegate else {
            return
        }
        for urlContext in urlContexts {
            appDelegate.handleOpenUrl(urlContext.url)
        }
    }

    // MARK: - User Activities

    // See the note on `scene(_:willConnectTo:options:)` for the `@available` hack.
    @available(iOS, deprecated: 13.0)
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let appDelegate else {
            return
        }
        _ = appDelegate.application(.shared, continue: userActivity, restorationHandler: { _ in })
    }

    // MARK: - Shortcut Items

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void,
    ) {
        guard let appDelegate else {
            completionHandler(false)
            return
        }
        appDelegate.application(.shared, performActionFor: shortcutItem, completionHandler: completionHandler)
    }

}
