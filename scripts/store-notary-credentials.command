#!/bin/zsh
clear
echo "Lock Anyway notarization credential setup"
echo
echo "This stores an Apple notarytool profile named:"
echo "  lock-anyway"
echo
echo "Use your Apple Developer Apple ID and an app-specific password."
echo "Nothing you type here is saved in the repository."
echo
xcrun notarytool store-credentials lock-anyway --team-id RJL9XWBZ9L
status=$?
echo
if [[ $status -eq 0 ]]; then
  echo "Notary credentials were saved. You can return to Codex now."
else
  echo "Credential setup failed with exit code $status."
fi
echo
echo "Press Return to close this window."
read
exit $status
