import CoreSpiceCLICore
import Foundation

@main
struct CoreSpiceCLIEntry {
  static func main() async {
    Foundation.exit(Int32(await CoreSpiceCLI.run()))
  }
}
