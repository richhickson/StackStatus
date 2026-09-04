cask "stackstatus" do
  version "0.1.0"
  sha256 "705b7ca78fc203696406b82a1652e65519588fc632d1072cf4da05783cd7d103"

  url "https://github.com/richhickson/StackStatus/releases/download/v#{version}/StackStatus.zip"
  name "StackStatus"
  desc "Menubar monitor for vendor status pages that answers them, me, or the internet"
  homepage "https://github.com/richhickson/StackStatus"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "StackStatus.app"

  zap trash: [
    "~/Library/Containers/com.helpfullyit.stackstatus",
    "~/Library/Preferences/com.helpfullyit.stackstatus.plist",
  ]
end
