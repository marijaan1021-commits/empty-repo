CallNote - a reminder for the calls you care about
================================================

callnote-release-20261104-065106.apk
  sha256 : 42843e19912595652403a7c23392297d27387dc9c2a9a3f69d5175fab321dddc
  sha1   : 30c2120e2488a5d55a654192c3e32087b148c87d
  size   : 46116469 bytes
  abis   : 'arm64-v8a' 'armeabi-v7a' 'x86_64'
  signer : CN=CallNote, OU=CallNote, O=CallNote, L=, ST=, C=US

Install
-------
  adb install -r callnote-release-20261104-065106.apk

or copy the apk to the phone and open it (you need "install from unknown
sources" for your file manager).

The package contains arm64-v8a, armeabi-v7a and x86_64, so it installs on
any phone.

First start
-----------
1. Allow the permissions when the app asks: notifications, contacts, the
   call log and phone state. The reminder is a notification - without the
   notification permission the phone stays silent. Phone state is what lets
   the app know the caller's number while the call is still ringing.
2. Add a note: pick a contact, type what you want to be reminded about and
   switch the note on.
3. That is all. The app watches the calls and tells you when one of the
   contacts with a note calls - within a few tens of milliseconds.

The app makes no network request.
