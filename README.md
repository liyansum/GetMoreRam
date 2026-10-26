# Get More Ram
A simple [StosSign](https://github.com/stossy11/StosSign) wrapper app that allows you to enable "Increased Memory Limit" for your sideloaded apps without using Xcode.

# How to use
1. Sideload this app
2. Go to settings, sign in your account that you used to sign the app you want to enable "Increased Memory Limit"
3. Go to "App IDs" page
4. Tap Refresh
5. Tap the app you want to enable "Increased Memory Limit"
6. Tap "Add Increased Memory Limit"
7. Reinstall the app from SideStore/AltStore
8. Check if you have "Increased Memory Limit"

# Credits
Stossy11 - For StosSign.
SideStore - Anisette Data fetching codes are stolen from SideStore

# Signing in with a SideStore account
Export your account from SideStore, import the resulting `.sideconf` here, then tap Sign in.
The exported Anisette identity is bound to the backend that provisioned it, so it cannot be
reused against another Anisette server (that is the `-45061` error). GetMoreRam keeps the
exported identifier and provisions its own `adi.pb` locally, which always matches.

# On-device Anisette
Anisette headers are generated on device with [AnisetteKit](https://github.com/mahee96/AnisetteKit),
which runs Apple's ADI libraries inside an in-process Unicorn emulator, so no Anisette server is
contacted. The libraries are not committed here: run `python3 Scripts/fetch_adi_libraries.py` once
before building, CI does it automatically. Turn the feature off in Settings to use a remote server.

AnisetteKit is licensed under AGPLv3, so builds that include it are covered by that license.
