#if canImport(AppKit)
import Foundation

public enum LoginOTPAssistantError: LocalizedError, Sendable {
    case automationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .automationFailed(let message):
            return message
        }
    }
}

public enum LoginOTPAssistant {
    public static func latestCodeFromAppleMail(for email: String) async throws -> String? {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let output = try await runAppleScript(
            mailLookupScript,
            environment: ["OTP_TARGET_EMAIL": email]
        )
        guard !output.isEmpty else { return nil }
        return extractUniqueSixDigitCode(from: output)
    }

    public static func fillCodeInArc(_ code: String, expectedEmail: String) async throws -> Bool {
        guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else { return false }
        guard !expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard expectedEmail.range(
            of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+$"#,
            options: .regularExpression
        ) != nil else { return false }
        let output = try await runAppleScript(
            arcFillScript,
            environment: [
                "OTP_CODE": code,
                "OTP_TARGET_EMAIL": expectedEmail,
            ]
        )
        return output.hasPrefix("filled")
    }

    public static func extractUniqueSixDigitCode(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{6})(?!\d)"#) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        let codes = Set(matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        })
        guard codes.count == 1 else { return nil }
        return codes.first
    }

    private static func runAppleScript(
        _ script: String,
        environment: [String: String]
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            var mergedEnvironment = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                mergedEnvironment[key] = value
            }
            process.environment = mergedEnvironment
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw LoginOTPAssistantError.automationFailed(error.localizedDescription)
            }
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LoginOTPAssistantError.automationFailed(
                    message?.isEmpty == false ? message! : "macOS automation permission was not available."
                )
            }
            return String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }

    private static let mailLookupScript = #"""
set targetEmail to system attribute "OTP_TARGET_EMAIL"
set cutoffDate to (current date) - 600
set resultText to ""
set matchedCount to 0
tell application "Mail"
    set messageCount to count of messages of inbox
    if messageCount > 50 then set messageCount to 50
    repeat with i from 1 to messageCount
        try
            set msg to message i of inbox
            set receivedAt to date received of msg
            if receivedAt is greater than or equal to cutoffDate then
                set recipientMatched to false
                repeat with recipientItem in to recipients of msg
                    try
                        ignoring case
                            if (address of recipientItem as text) is targetEmail then set recipientMatched to true
                        end ignoring
                    end try
                end repeat

                if recipientMatched then
                    set senderText to sender of msg as text
                    set subjectText to subject of msg as text
                    set senderIsOpenAI to false
                    ignoring case
                        if senderText contains "@openai.com" or senderText contains ".openai.com" then set senderIsOpenAI to true
                        if senderText contains "@chatgpt.com" or senderText contains ".chatgpt.com" then set senderIsOpenAI to true
                    end ignoring
                    set looksLikeCodeMessage to false
                    ignoring case
                        if subjectText contains "verification" or subjectText contains "security code" or subjectText contains "one-time" or subjectText contains "sign in" then set looksLikeCodeMessage to true
                    end ignoring
                    if senderIsOpenAI and looksLikeCodeMessage then
                        set bodyText to content of msg as text
                        if (length of bodyText) > 2000 then set bodyText to text 1 thru 2000 of bodyText
                        set resultText to resultText & subjectText & linefeed & bodyText & linefeed
                        set matchedCount to matchedCount + 1
                        if matchedCount is greater than or equal to 5 then exit repeat
                    end if
                end if
            end if
        end try
    end repeat
end tell
return resultText
"""#

    private static let arcFillScript = #"""
set otpCode to system attribute "OTP_CODE"
set targetEmail to system attribute "OTP_TARGET_EMAIL"
set matchingTab to missing value
set matchCount to 0
tell application "Arc"
    repeat with browserWindow in windows
        repeat with browserTab in tabs of browserWindow
            try
                set tabURL to URL of browserTab as text
                if tabURL starts with "https://auth.openai.com/" or tabURL starts with "https://chatgpt.com/" or tabURL starts with "https://openai.com/" then
                    set probeResult to execute browserTab javascript "(function(){const expected='" & targetEmail & "'.toLowerCase();const host=location.hostname.toLowerCase();if(!(host==='openai.com'||host.endsWith('.openai.com')||host==='chatgpt.com'||host.endsWith('.chatgpt.com')))return 'untrusted';const body=(document.body&&document.body.innerText||'').toLowerCase();if(!body.includes(expected))return 'wrong-account';if(!/(verification|verify|one[- ]time|security code|enter.{0,20}code|check your email)/i.test(body))return 'not-code-page';const visible=e=>!e.disabled&&(e.offsetWidth||e.offsetHeight||e.getClientRects().length);const inputs=[...document.querySelectorAll('input')].filter(visible);const meta=e=>((e.autocomplete||'')+' '+(e.name||'')+' '+(e.id||'')+' '+(e.placeholder||'')).toLowerCase();const candidates=inputs.filter(e=>e.autocomplete==='one-time-code'||/(otp|verification|security|code)/.test(meta(e))||(e.inputMode==='numeric'&&(e.maxLength<0||e.maxLength>=6)));const digits=inputs.filter(e=>e.maxLength===1&&(e.inputMode==='numeric'||/code|otp/.test(meta(e))));return (candidates.length===1||digits.length===6)?'candidate':'ambiguous';})()"
                    if probeResult is "candidate" then
                        set matchCount to matchCount + 1
                        set matchingTab to browserTab
                    end if
                end if
            end try
        end repeat
    end repeat
    if matchCount is not 1 then return "not-found-or-ambiguous"
    try
        set jsResult to execute matchingTab javascript "(function(){const code='" & otpCode & "';const expected='" & targetEmail & "'.toLowerCase();const body=(document.body&&document.body.innerText||'').toLowerCase();if(!body.includes(expected))return 'wrong-account';const visible=e=>!e.disabled&&(e.offsetWidth||e.offsetHeight||e.getClientRects().length);const inputs=[...document.querySelectorAll('input')].filter(visible);const meta=e=>((e.autocomplete||'')+' '+(e.name||'')+' '+(e.id||'')+' '+(e.placeholder||'')).toLowerCase();const candidates=inputs.filter(e=>e.autocomplete==='one-time-code'||/(otp|verification|security|code)/.test(meta(e))||(e.inputMode==='numeric'&&(e.maxLength<0||e.maxLength>=6)));const setValue=(el,v)=>{const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;setter.call(el,v);el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));};if(candidates.length===1){setValue(candidates[0],code);candidates[0].focus();}else{const digits=inputs.filter(e=>e.maxLength===1&&(e.inputMode==='numeric'||/code|otp/.test(meta(e))));if(digits.length!==code.length)return 'ambiguous';digits.forEach((e,i)=>setValue(e,code[i]));digits[digits.length-1].focus();}const buttons=[...document.querySelectorAll('button,input[type=submit]')].filter(visible).filter(e=>!/disabled/i.test(e.getAttribute('aria-disabled')||''));const verify=buttons.filter(e=>/(verify|continue|confirm|next|submit)/i.test((e.innerText||e.value||'').trim()));if(verify.length===1){setTimeout(()=>verify[0].click(),120);return 'filled-and-submitted';}return 'filled';})()"
        return jsResult
    end try
end tell
return "not-found"
"""#
}
#endif
