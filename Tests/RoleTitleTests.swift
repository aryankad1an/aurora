import Foundation

// The roles a company page shows: scraped ledger text cut down to the role's
// name. Run with:
//
//   swiftc -parse-as-library Aurora/Models/RoleTitle.swift Tests/RoleTitleTests.swift -o /tmp/rt && /tmp/rt

@main
struct RoleTitleTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static func clean(_ raw: String) -> String? { RoleTitle.clean(raw) }

    static func main() {
        // Labelled fields run together.
        expect(clean("Company Name: AcmeRole: Software Developer (Contract)"), "Software Developer (Contract)", "role after a glued company label")
        expect(clean("Company: Acme Role:\u{a0} Devops Engineer"), "Devops Engineer", "no-break space after the label")
        expect(clean("Company Name : AcmeRoles : SDE 1 and SDE 2Batches : 2024,23"), "SDE 1 and SDE 2", "roles up to the next label")
        expect(clean("!Position: Associate Data Engineer IQualifications: Bachelor’s"), "Associate Data Engineer I", "position label")
        expect(clean("Software Engineer (2025 Batch)𝐑𝐨𝐥𝐞: Software Engineer𝐁𝐚𝐭𝐜𝐡 𝐞𝐥𝐢𝐠"), "Software Engineer", "styled letters")
        expect(clean("company name: acme groupbatch: 2025/2024 passoutsrole: junior software engineer"), "Junior Software Engineer", "all lower case is title-cased")
        expect(clean("!!Role - sde 1 Exp - fresher"), "SDE 1", "dash labels, acronyms kept upper case")
        expect(clean("Company Name: Acme"), nil, "only a company: nothing to show")
        expect(clean("Cloud Engineer TraineeQualifications:  B.Tech (IT, CSE)"), "Cloud Engineer Trainee", "text before the first label")

        // Glued tails, batches, experience and pay.
        expect(clean("Software QA Trainee – FreshersApply Now"), "Software QA Trainee", "fresher call and Apply Now")
        expect(clean("Software Engineer (Devops)For 2021, 2022 gards"), "Software Engineer (Devops)", "glued grad years")
        expect(clean("Backend EngineerData Engineer IOS Engineer"), "Backend Engineer", "roles run together: the first")
        expect(clean("Hiring Entry-Level Software Engineers (0-3 Years) - JobsNet"), "Entry-Level Software Engineers", "hiring, experience and job board")
        expect(clean("Software Development Engineer (0-2 Years)BE/BTech/BSC"), "Software Development Engineer", "degrees glued after a bracket")
        expect(clean("Hiring Freshers For Software Developer Role | 12-15 LPA"), "Software Developer", "freshers-for, role and pay")
        expect(clean("Full Stack Developer| 0-2 Year's"), "Full Stack Developer", "Year's")
        expect(clean("Entry-Level SDE in Test (1-3 Years experience)"), "Entry-Level SDE in Test", "experience in brackets")
        expect(clean("Software Engineer - Freshers/Early Careers"), "Software Engineer", "fresher tail with a slash")
        expect(clean("Company Name: AcmeRole : Software Engineer ( Backend, Frontend,"), "Software Engineer", "value cut off inside brackets")
        expect(clean("DotNet Developer Fresher 2025/2024 batch passouts eligible"), "DotNet Developer", "batch passouts")
        expect(clean("26-3091: Junior Full Stack Developer"), "Junior Full Stack Developer", "requisition number")

        // Clean titles stay as they are.
        for title in ["Software Engineer I - Backend Leaning FullStack", "SDE-1 (Open Campus 2025 drive)",
                      "Freshers & Experienced Software Engineers", "PeopleSoft HCM - Techno/Functional Developer",
                      "Multiple engineering roles", "C++ Developer"] {
            expect(clean(title), title, "unchanged: \(title)")
        }

        // A list: cleaned, empty ones dropped, repeats once.
        expect(RoleTitle.cleaned(["Company Name: Acme", "Hiring SDE 1", "Company: AcmeRole: SDE 1", "Data Engineer"]),
               ["SDE 1", "Data Engineer"], "list without blanks or repeats")

        print(failures == 0 ? "All passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
