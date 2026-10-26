//
//  SettingsView.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/14.
//

import SwiftUI
import UniformTypeIdentifiers
import StosSign_API
import StosSign_Auth
import StosSign_Common

struct SettingsView: View {

    @State var email = ""
    @State var teamId = ""
    @StateObject var viewModel : LoginViewModel
    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var importResultShow = false
    @State private var importResultInfo = ""
    @State private var isImportingSideStoreAccount = false
    @State private var isSideStorePasswordPromptPresented = false
    @State private var pendingSideStoreAccountData: Data?
    @State private var sideStoreExportPassword = ""
    @State private var sideStoreImportError = ""
    @State private var pendingSideStoreImportSuccess: String?
    

    var body: some View {
        Form {

            Section {
                if sharedModel.isLogin {
                    HStack {
                        Text("Email")
                        Spacer()
                        Text(email)
                    }
                    HStack {
                        Text("Team ID")
                        Spacer()
                        Text(teamId)
                    }
                } else {
                    Button("Sign in") {
                        viewModel.loginModalShow = true
                    }
                    
                    Button("Import SideStore Account") {
                        isImportingSideStoreAccount = true
                    }
                }
            } header: {
                Text("Account")
            }
            
            Section {
                HStack {
                    Text("Anisette Server URL")
                    Spacer()
                    TextField("", text: $sharedModel.anisetteServerURL)
                        .multilineTextAlignment(.trailing)
                }
            }
            
            Section {
                Button("Clean Up Keychain") {
                    cleanUp()
                }
            } footer: {
                Text("Import a JSON or encrypted .sideconf account exported from SideStore. Enter the export password when prompted, then tap Sign in. If the export omits your Apple ID password, enter it on the sign-in screen.\n\nClean Up Keychain removes this app's saved account and Anisette identity.")
            }
        }
        .alert("Error", isPresented: $errorShow){
            Button("OK".loc, action: {
            })
        } message: {
            Text(errorInfo)
        }
        .alert("SideStore Account", isPresented: $importResultShow){
            Button("OK".loc, action: {
            })
        } message: {
            Text(importResultInfo)
        }
        .fileImporter(
            isPresented: $isImportingSideStoreAccount,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            importSideStoreAccount(result)
        }
        
        .sheet(isPresented: $viewModel.loginModalShow, onDismiss: {
            viewModel.cancelAuthentication()
            viewModel.appleID = ""
            viewModel.password = ""
            viewModel.verificationCode = ""
            viewModel.logs = ""
        }) {
            loginModal
        }
        .sheet(isPresented: $viewModel.teamSelectionShow) {
            teamSelectionView
        }
        .sheet(isPresented: $isSideStorePasswordPromptPresented, onDismiss: {
            let successMessage = pendingSideStoreImportSuccess
            pendingSideStoreAccountData = nil
            sideStoreExportPassword = ""
            sideStoreImportError = ""
            pendingSideStoreImportSuccess = nil
            if let successMessage {
                importResultInfo = successMessage
                importResultShow = true
            }
        }) {
            sideStoreExportPasswordSheet
        }
    }

    var sideStoreExportPasswordSheet: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("Export password", text: $sideStoreExportPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Enter the password chosen when exporting this .sideconf file from SideStore. Decryption takes place on this device.")
                }
                if !sideStoreImportError.isEmpty {
                    Section {
                        Text(sideStoreImportError)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button("Import Account") {
                        decryptSideStoreAccount()
                    }
                }
            }
            .navigationTitle("SideStore Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        pendingSideStoreImportSuccess = nil
                        isSideStorePasswordPromptPresented = false
                    }
                }
            }
        }
    }
    
    var loginModal: some View {
        NavigationView {
            Form {
                Section {
                    TextField("", text: $viewModel.appleID)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .disabled(viewModel.isLoginInProgress)
                } header: {
                    Text("Apple ID")
                }
                Section {
                    SecureField("", text: $viewModel.password)
                        .disabled(viewModel.isLoginInProgress)
                } header: {
                    Text("Password")
                }
                if viewModel.needVerificationCode {
                    Section {
                        TextField("", text: $viewModel.verificationCode)
                            .disabled(viewModel.isVerificationCodeSubmitting)
                    } header: {
                        Text("Verification Code")
                    }
                }
                Section {
                    Button("Continue") {
                        Task{ await loginButtonClicked() }
                    }
                    .disabled(continueButtonDisabled)
                }
                
                Section {
                    Text(viewModel.logs)
                        .font(.system(.subheadline, design: .monospaced))
                } header: {
                    Text("Debugging")
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        viewModel.cancelAuthentication()
                        viewModel.loginModalShow = false
                    }
                }
            }
        }
        .onAppear {
            if let email = Keychain.shared.appleIDEmailAddress, let password = Keychain.shared.appleIDPassword {
                viewModel.appleID = email
                viewModel.password = password
            }
        }
    }
    
    var teamSelectionView: some View {
        NavigationView {
            List {
                ForEach(Array(viewModel.availableTeams.enumerated()), id: \.offset) { _, team in
                    Button {
                        selectTeam(team)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(team.name)
                                .foregroundStyle(.primary)
                            Text("\(team.identifier) · \(teamTypeDescription(team.type))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Choose Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        cancelTeamSelection()
                    }
                }
            }
        }
    }
    
    func loginButtonClicked() async {
        do {
            if viewModel.needVerificationCode {
                viewModel.submitVerificationCode()
                return
            }
            
            let result = try await viewModel.authenticate()
            if result {
                await MainActor.run {
                    viewModel.loginModalShow = false
                    email = sharedModel.account!.appleID
                    teamId = ""
                }

                if viewModel.availableTeams.count == 1,
                   let team = viewModel.availableTeams.first {
                    await MainActor.run {
                        selectTeam(team)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await MainActor.run {
                        viewModel.teamSelectionShow = true
                    }
                }
            }
            
        } catch is CancellationError {
            return
        } catch {
            errorInfo = error.detailedDescription
            errorShow = true
        }
    }

    private var continueButtonDisabled: Bool {
        if viewModel.needVerificationCode {
            return viewModel.isVerificationCodeSubmitting ||
                viewModel.verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return viewModel.isLoginInProgress
    }
    
    func cleanUp() {
        viewModel.cancelAuthentication()
        viewModel.appleID = ""
        viewModel.password = ""
        viewModel.verificationCode = ""
        viewModel.logs = ""
        Keychain.shared.adiPb = nil
        Keychain.shared.identifier = nil
        Keychain.shared.anisetteIdentitySource = nil
        Keychain.shared.anisetteIdentityProfile = nil
        Keychain.shared.appleIDPassword = nil
        Keychain.shared.appleIDEmailAddress = nil
        AnisetteDataHelper.shared.resetClientInfo()
        sharedModel.session = nil
        sharedModel.account = nil
        sharedModel.team = nil
        sharedModel.isLogin = false
        viewModel.availableTeams = []
        viewModel.teamSelectionShow = false
        email = ""
        teamId = ""
    }
    
    func importSideStoreAccount(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                throw "No file selected."
            }
            
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > 16 * 1024 * 1024 {
                throw "This file is too large for a SideStore account export. Choose a JSON or .sideconf account file."
            }
            let data = try Data(contentsOf: url)
            if SideStoreAccountImporter.requiresPassword(for: data) {
                pendingSideStoreAccountData = data
                sideStoreExportPassword = ""
                sideStoreImportError = ""
                pendingSideStoreImportSuccess = nil
                isSideStorePasswordPromptPresented = true
                return
            }
            let account = try SideStoreAccountImporter.decodeAccount(from: data)
            let storedAccount = try SideStoreAccountImporter.storeAccount(account)
            importResultInfo = applyImportedSideStoreAccount(storedAccount)
            importResultShow = true
        } catch {
            errorInfo = error.detailedDescription
            errorShow = true
        }
    }
    
    func decryptSideStoreAccount() {
        guard let data = pendingSideStoreAccountData else { return }
        do {
            let account = try SideStoreAccountImporter.decodeAccount(
                from: data, filePassword: sideStoreExportPassword
            )
            let storedAccount = try SideStoreAccountImporter.storeAccount(account)
            pendingSideStoreImportSuccess = applyImportedSideStoreAccount(storedAccount)
            isSideStorePasswordPromptPresented = false
        } catch {
            sideStoreImportError = error.detailedDescription
        }
    }

    func applyImportedSideStoreAccount(_ account: SideStoreAccount) -> String {
        viewModel.appleID = account.email
        viewModel.password = account.password
        sharedModel.session = nil
        sharedModel.account = nil
        sharedModel.team = nil
        sharedModel.isLogin = false
        viewModel.availableTeams = []
        viewModel.teamSelectionShow = false
        email = account.email
        teamId = ""
        if account.hasApplePassword {
            return "Imported \(account.email) and its Anisette identity.\nTap Sign in to authenticate."
        }
        return "Imported \(account.email) and its Anisette identity.\nTap Sign in and enter your Apple ID password to authenticate."
    }

    func selectTeam(_ team: Team) {
        sharedModel.team = team
        sharedModel.isLogin = true
        email = sharedModel.account?.appleID ?? email
        teamId = team.identifier
        viewModel.availableTeams = []
        viewModel.teamSelectionShow = false
    }
    
    func cancelTeamSelection() {
        viewModel.availableTeams = []
        viewModel.teamSelectionShow = false
        sharedModel.session = nil
        sharedModel.account = nil
        sharedModel.team = nil
        sharedModel.isLogin = false
        email = ""
        teamId = ""
    }
    
    func teamTypeDescription(_ type: TeamType) -> String {
        switch type {
        case .free:
            return "Free"
        case .individual:
            return "Individual"
        case .organization:
            return "Organization"
        case .unknown:
            return "Unknown"
        }
    }
    
}
