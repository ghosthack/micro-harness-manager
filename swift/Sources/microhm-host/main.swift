import Foundation
import MicrohmCore

// The headless background host (Java's `McpHost`), and with `--phone-only` the phone page
// on its own (Java's `PhoneMain`). See `McpHost`.
setvbuf(stdout, nil, _IOLBF, 0)
exit(McpHost.main(Array(CommandLine.arguments.dropFirst())))
