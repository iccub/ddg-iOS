//
//  DuckPlayerNavigationHandler.swift
//  DuckDuckGo
//
//  Copyright © 2024 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import ContentScopeScripts
import WebKit
import Core
import Common
import BrowserServicesKit
import DuckPlayer
import os.log

final class DuckPlayerNavigationHandler {
    
    var duckPlayer: DuckPlayerProtocol
    var referrer: DuckPlayerReferrer = .other
    var lastHandledVideoID: String?
    var featureFlagger: FeatureFlagger
    var appSettings: AppSettings
    
    private struct Constants {
        static let SERPURL =  "duckduckgo.com/"
        static let refererHeader = "Referer"
        static let templateDirectory = "pages/duckplayer"
        static let templateName = "index"
        static let templateExtension = "html"
        static let localhost = "http://localhost"
        static let duckPlayerAlwaysString = "always"
        static let duckPlayerDefaultString = "default"
        static let settingsKey = "settings"
        static let httpMethod = "GET"
        static let watchInYoutubePath = "openInYoutube"
        static let watchInYoutubeVideoParameter = "v"
        static let urlInternalReferrer = "embeds_referring_euri"
        static let youtubeScheme = "youtube://"
        static let duckPlayerScheme = URL.NavigationalScheme.duck.rawValue
    }
    
    init(duckPlayer: DuckPlayerProtocol = DuckPlayer(),
         featureFlagger: FeatureFlagger = AppDependencyProvider.shared.featureFlagger,
         appSettings: AppSettings) {
        self.duckPlayer = duckPlayer
        self.featureFlagger = featureFlagger
        self.appSettings = appSettings
    }
    
    static var htmlTemplatePath: String {
        guard let file = ContentScopeScripts.Bundle.path(forResource: Constants.templateName,
                                                         ofType: Constants.templateExtension,
                                                         inDirectory: Constants.templateDirectory) else {
            assertionFailure("YouTube Private Player HTML template not found")
            return ""
        }
        return file
    }

    static func makeDuckPlayerRequest(from originalRequest: URLRequest) -> URLRequest {
        guard let (youtubeVideoID, timestamp) = originalRequest.url?.youtubeVideoParams else {
            assertionFailure("Request should have ID")
            return originalRequest
        }
        return makeDuckPlayerRequest(for: youtubeVideoID, timestamp: timestamp)
    }

    static func makeDuckPlayerRequest(for videoID: String, timestamp: String?) -> URLRequest {
        var request = URLRequest(url: .youtubeNoCookie(videoID, timestamp: timestamp))
        request.addValue(Constants.localhost, forHTTPHeaderField: Constants.refererHeader)
        request.httpMethod = Constants.httpMethod
        return request
    }

    static func makeHTMLFromTemplate() -> String {
        guard let html = try? String(contentsOfFile: htmlTemplatePath) else {
            assertionFailure("Should be able to load template")
            return ""
        }
        return html
    }
    
    private func performNavigation(_ request: URLRequest, responseHTML: String, webView: WKWebView) {
        webView.loadSimulatedRequest(request, responseHTML: responseHTML)
    }
    
    private func performRequest(request: URLRequest, webView: WKWebView) {
        let html = Self.makeHTMLFromTemplate()
        let duckPlayerRequest = Self.makeDuckPlayerRequest(from: request)
        performNavigation(duckPlayerRequest, responseHTML: html, webView: webView)
    }
    
    // Handle URL changes not triggered via Omnibar
    // such as changes triggered via JS
    @MainActor
    private func handleURLChange(url: URL?, webView: WKWebView) {

        guard let url else { return }
        
        guard featureFlagger.isFeatureOn(.duckPlayer) else {
            return
        }
        
        // This is passed to the FE overlay at init to disable the overlay for one video
        duckPlayer.settings.allowFirstVideo = false
        
        if let (videoID, _) = url.youtubeVideoParams,
            videoID == lastHandledVideoID {
            Logger.duckPlayer.debug("URL (\(url.absoluteString) already handled, skipping")
            return
        }
        
        // Handle Youtube internal links like "Age restricted" and "Copyright restricted" videos
         // These should not be handled by DuckPlayer
        if url.isYoutubeVideo,
            url.hasWatchInYoutubeQueryParameter {
                duckPlayer.settings.allowFirstVideo = true
            return
         }
                
        if url.isYoutubeVideo,
            !url.isDuckPlayer,
            let (videoID, timestamp) = url.youtubeVideoParams,
            duckPlayer.settings.mode == .enabled || duckPlayer.settings.mode == .alwaysAsk {
            
            Logger.duckPlayer.debug("Handling URL change: \(url.absoluteString)")
            webView.load(URLRequest(url: URL.duckPlayer(videoID, timestamp: timestamp)))
            lastHandledVideoID = videoID
        }
    }
    
    // Get the duck:// URL youtube-no-cookie URL
    func getDuckURLFor(_ url: URL) -> URL {
        guard let (youtubeVideoID, timestamp) = url.youtubeVideoParams,
                url.isDuckPlayer,
                !url.isDuckURLScheme,
                duckPlayer.settings.mode != .disabled
        else {
            return url
        }
        return URL.duckPlayer(youtubeVideoID, timestamp: timestamp)
    }
    
    private var isYouTubeAppInstalled: Bool {
        if let youtubeURL = URL(string: Constants.youtubeScheme) {
            return UIApplication.shared.canOpenURL(youtubeURL)
        }
        return false
    }
    
    private func isSERPLink(navigationAction: WKNavigationAction) -> Bool {
        guard let referrer = navigationAction.request.allHTTPHeaderFields?[Constants.refererHeader] else {
            return false
        }
        if referrer.contains(Constants.SERPURL) {
            return true
        }
        return false
    }
    
}

extension DuckPlayerNavigationHandler: DuckNavigationHandling {

    // Handle rendering the simulated request if the URL is duck://
    // and DuckPlayer is either enabled or alwaysAsk
    @MainActor
    func handleNavigation(_ navigationAction: WKNavigationAction, webView: WKWebView) {
        
        Logger.duckPlayer.debug("Handling DuckPlayer Player Navigation for \(navigationAction.request.url?.absoluteString ?? "")")

        // This is passed to the FE overlay at init to disable the overlay for one video
        duckPlayer.settings.allowFirstVideo = false
        
        guard let url = navigationAction.request.url else { return }
        
        guard featureFlagger.isFeatureOn(.duckPlayer) else {
            return
        }
        
        // Handle Youtube internal links like "Age restricted" and "Copyright restricted" videos
        // These should not be handled by DuckPlayer
        if url.isYoutubeVideo,
           url.hasWatchInYoutubeQueryParameter {
                return
        }
        
        // Handle Open in Youtube Links
        // duck://player/openInYoutube?v=12345
        if url.scheme == Constants.duckPlayerScheme,
           let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
           urlComponents.path == "/\(Constants.watchInYoutubePath)",
           let videoParameterItem = urlComponents.queryItems?.first(where: { $0.name == Constants.watchInYoutubeVideoParameter }),
           let id = videoParameterItem.value,
           let newURL = URL.youtube(id, timestamp: nil).addingWatchInYoutubeQueryParameter() {

            Pixel.fire(pixel: Pixel.Event.duckPlayerWatchOnYoutube)

            // These links should always skip the overlay
            duckPlayer.settings.allowFirstVideo = true

            // Attempt to open in YouTube app (if installed) or load in webView
            if isSERPLink(navigationAction: navigationAction),
               appSettings.allowUniversalLinks,
               isYouTubeAppInstalled,
                let url = URL(string: "\(Constants.youtubeScheme)\(id)") {
                UIApplication.shared.open(url)
            } else {
                webView.load(URLRequest(url: newURL))
            }
            return
        }
        
        
        // Daily Unique View Pixel
        if url.isDuckPlayer,
           duckPlayer.settings.mode != .disabled {
            let setting = duckPlayer.settings.mode == .enabled ? Constants.duckPlayerAlwaysString : Constants.duckPlayerDefaultString
            DailyPixel.fire(pixel: Pixel.Event.duckPlayerDailyUniqueView, withAdditionalParameters: [Constants.settingsKey: setting])
            
        }
        
        // Pixel for Views From Youtube
        if referrer == .youtube,
            duckPlayer.settings.mode == .enabled {
            Pixel.fire(pixel: Pixel.Event.duckPlayerViewFromYoutubeAutomatic)
        }
        
        
        if url.isDuckURLScheme {
           
            // If DuckPlayer is Enabled or in ask mode, render the video
            if duckPlayer.settings.mode == .enabled || duckPlayer.settings.mode == .alwaysAsk,
               !url.hasWatchInYoutubeQueryParameter {
                let newRequest = Self.makeDuckPlayerRequest(from: URLRequest(url: url))
                
                Logger.duckPlayer.debug("DP: Loading Simulated Request for \(navigationAction.request.url?.absoluteString ?? "")")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.performRequest(request: newRequest, webView: webView)
                }
                            
            // Otherwise, just redirect to YouTube
            } else {
                if let (videoID, timestamp) = url.youtubeVideoParams {
                    let youtubeURL = URL.youtube(videoID, timestamp: timestamp)
                    let request = URLRequest(url: youtubeURL)
                    webView.load(request)
                }
            }
            return
        }
        
    }
    
    // DecidePolicyFor handler to redirect relevant requests
    // to duck://player
    @MainActor
    func handleDecidePolicyFor(_ navigationAction: WKNavigationAction,
                               completion: @escaping (WKNavigationActionPolicy) -> Void,
                               webView: WKWebView) {
        
        guard let url = navigationAction.request.url else {
            completion(.cancel)
            return
        }
        
        guard featureFlagger.isFeatureOn(.duckPlayer) else {
            completion(.allow)
            return
        }
        
        // This is passed to the FE overlay at init to disable the overlay for one video
        duckPlayer.settings.allowFirstVideo = false
        
        if let (videoID, _) = url.youtubeVideoParams,
           videoID == lastHandledVideoID,
            !url.hasWatchInYoutubeQueryParameter {
            Logger.duckPlayer.debug("DP: DecidePolicy: URL (\(url.absoluteString)) already handled, skipping")
            completion(.cancel)
            return
        }
        
         // Handle Youtube internal links like "Age restricted" and "Copyright restricted" videos
         // These should not be handled by DuckPlayer and not include overlays
         if url.isYoutubeVideo,
            url.hasWatchInYoutubeQueryParameter {
                duckPlayer.settings.allowFirstVideo = true
                completion(.allow)
                return
         }

        // Pixel for Views From SERP
        if isSERPLink(navigationAction: navigationAction),
           duckPlayer.settings.mode == .enabled, !url.isDuckPlayer {
            Pixel.fire(pixel: Pixel.Event.duckPlayerViewFromSERP, debounce: 2)
        } else {
            Pixel.fire(pixel: Pixel.Event.duckPlayerViewFromOther, debounce: 2)
        }
        
        
        if url.isYoutubeVideo,
           !url.isDuckPlayer,
            duckPlayer.settings.mode == .enabled || duckPlayer.settings.mode == .alwaysAsk {
                Logger.duckPlayer.debug("DP: Handling decidePolicy for Duck Player with \(url.absoluteString)")
                completion(.cancel)
                handleURLChange(url: url, webView: webView)
                return
        }
        
        completion(.allow)
    }
    
    @MainActor
    func handleJSNavigation(url: URL?, webView: WKWebView) {
        
        guard featureFlagger.isFeatureOn(.duckPlayer) else {
            return
        }
        
        handleURLChange(url: url, webView: webView)
    }
    
    @MainActor
    func handleGoBack(webView: WKWebView) {
        
        Logger.duckPlayer.debug("DP: Handling Back Navigation")
        
        guard featureFlagger.isFeatureOn(.duckPlayer) else {
            webView.goBack()
            return
        }
        
        lastHandledVideoID = nil
        webView.stopLoading()
        
        // Check if the back list has items
        guard !webView.backForwardList.backList.isEmpty else {
            webView.goBack()
            return
        }
        
        // Find the last non-YouTube video URL in the back list
        // and navigate to it
        let backList = webView.backForwardList.backList
        var nonYoutubeItem: WKBackForwardListItem?
        
        for item in backList.reversed() where !item.url.isYoutubeVideo && !item.url.isDuckPlayer {
            nonYoutubeItem = item
            break
        }
        
        if let nonYoutubeItem = nonYoutubeItem, duckPlayer.settings.mode == .enabled {
            Logger.duckPlayer.debug("DP: Navigating back to \(nonYoutubeItem.url.absoluteString)")
            webView.go(to: nonYoutubeItem)
        } else {
            Logger.duckPlayer.debug("DP: Navigating back to previous page")
            webView.goBack()
        }
    }
    
    // Handle Reload for DuckPlayer Videos
    @MainActor
    func handleReload(webView: WKWebView) {
        
        guard featureFlagger.isFeatureOn(.duckPlayer) else {
            webView.reload()
            return
        }
        
        lastHandledVideoID = nil
        webView.stopLoading()
        if let url = webView.url, url.isDuckPlayer,
            !url.isDuckURLScheme,
            let (videoID, timestamp) = url.youtubeVideoParams,
            duckPlayer.settings.mode == .enabled || duckPlayer.settings.mode == .alwaysAsk {
            Logger.duckPlayer.debug("DP: Handling DuckPlayer Reload for \(url.absoluteString)")
            webView.load(URLRequest(url: .duckPlayer(videoID, timestamp: timestamp)))
        } else {
            webView.reload()
        }
    }
    
    @MainActor
    func handleAttach(webView: WKWebView) {
        
        guard featureFlagger.isFeatureOn(.duckPlayer) else {
            return
        }
        
        if let url = webView.url, url.isDuckPlayer,
            !url.isDuckURLScheme,
            duckPlayer.settings.mode == .enabled || duckPlayer.settings.mode == .alwaysAsk {
            Logger.duckPlayer.debug("DP: Handling Initial Load of a video for \(url.absoluteString)")
            handleReload(webView: webView)
        }
        
    }

}
