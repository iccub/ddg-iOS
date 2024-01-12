//
//  SettingsPrivacyProView.swift
//  DuckDuckGo
//
//  Copyright © 2023 DuckDuckGo. All rights reserved.
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

import SwiftUI
import UIKit

#if SUBSCRIPTION
@available(iOS 15.0, *)
struct SettingsPrivacyProView: View {
    
    @EnvironmentObject var viewModel: SettingsViewModel
    
    private var privacyProDescriptionView: some View {
        VStack(alignment: .leading) {
            Text(UserText.settingsPProSubscribe).daxBodyRegular()
            Group {
                Text(UserText.settingsPProDescription).daxFootnoteRegular().padding(.bottom, 5)
                Text(UserText.settingsPProFeatures).daxFootnoteRegular()
            }.foregroundColor(Color(designSystemColor: .textSecondary))
        }
    }
    
    private var learnMoreView: some View {
        Text(UserText.settingsPProLearnMore)
            .daxBodyRegular()
            .foregroundColor(Color.init(designSystemColor: .accent))
    }
    
    private var manageSubscriptionView: some View {
        Text(UserText.settingsPProManageSubscription)
            .daxBodyRegular()
            .foregroundColor(Color.init(designSystemColor: .accent))
    }
    
    
    private var purchaseSubscriptionView: some View {
        return Group {
            SettingsCustomCell(content: { privacyProDescriptionView })
            NavigationLink(destination: SubscriptionFlowView(viewModel: SubscriptionFlowViewModel())) {
                SettingsCustomCell(content: { learnMoreView })
            }
        }
    }
    
    private var subscriptionDetailsView: some View {
        return Group {
            SettingsCellView(label: UserText.settingsPProVPNTitle,
                             subtitle: viewModel.state.networkProtection.status != "" ? viewModel.state.networkProtection.status : nil,
                             action: { viewModel.presentLegacyView(.netP) },
                             asLink: true,
                             disclosureIndicator: true)
            
            SettingsCellView(label: UserText.settingsPProDBPTitle, subtitle: UserText.settingsPProDBPSubTitle)
            SettingsCellView(label: UserText.settingsPProITRTitle, subtitle: UserText.settingsPProITRSubTitle)
            
            NavigationLink(destination: SubscriptionFlowView(viewModel: SubscriptionFlowViewModel())) {
                SettingsCustomCell(content: { manageSubscriptionView })
            }
        }
    }
    
    var body: some View {
        
        if viewModel.state.privacyPro.enabled {
            Section(header: Text(UserText.settingsPProSection)) {
                if viewModel.state.privacyPro.hasActiveSubscription {
                    subscriptionDetailsView
                } else {
                    purchaseSubscriptionView
                }
            }
        }
    }
}
#endif