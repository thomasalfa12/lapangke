import Foundation

let arguments = CommandLine.arguments
if arguments.dropFirst().contains(where: CLI.flags.contains) {
    Task.detached {
        let code = await CLI.run(arguments)
        exit(code)
    }
    dispatchMain()
} else {
    LapangkeApp.main()
}
