# 5c-Six: iPhone 5C to iOS 6.1.4

This project can currently only achieve the system installation and boot startup of  
iOS 6.1.4 (10B350). If you want to fix the functions in your device, please wait for  
Github: `@MC-XiaoXiao` to release the official version...

This is a standalone macOS project for the experimental, tethered iOS 6.1.4 (10B350)  
cross-boot on iPhone5,3, based on Kaiden's guide:  
<https://kaidenac.com/posts/downgrading-the-iphone-5c-to-ios-6/>

The project keeps its own script, boot firmware, keys, SSH ramdisk, utilities,  
dynamic libraries, configuration, and `fixkeybag` binary.

## Requirements

- Intel macOS and macOS 12.0+, Xcode Command Line Tools
- iPhone5,3 connected by USB and a known way to enter DFU mode
- At least 8 GB free space for the IPSW, decrypted RootFS, and working files
- Internet access to look up and download the iPhone5,2 iOS 6.1.4 (10B350) IPSW

## Commands

Run these from this directory:

```bash
./install.sh install
./install.sh boot
```

- `install` prepares the 10B350 RootFS, boots the bundled 11A470a SSH ramdisk,  
  and installs the system. When prompted, press Enter to repartition the phone  
  and continue. This erases all device data.
- `boot` enters pwned DFU, loads the bundled pwned-iBSS stage, and tether-boots  
  the installed iOS 6 system. Run it after every shutdown or reboot. The script  
  uses cached boot images when valid and rebuilds them automatically if needed.

If no compatible iPhone5,2 10B350 IPSW is found in the project directory or download  
cache, the script opens an arrow-key menu. Use Up/Down to choose an option and  
press Enter to confirm; press Ctrl-C to cancel:

1. Select a local IPSW using the macOS file chooser.
2. Download the IPSW from Apple's CDN. The download URL is looked up through  
   the ipsw.me API, and is checked against the API's file size and SHA-256.

The first `install` can take a while: it may download the IPSW, decrypt the 10B350  
filesystem, and stream it to the phone. Keep the USB connection stable.

If installation stops after repartitioning, running `install` again repeats the partition  
and format steps and erases device data again. To return to the stock partition layout,  
restore the device with an official iPhone5,3 10.3.3/10.3.4 IPSW.
