cask "stackstatus" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE"

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
