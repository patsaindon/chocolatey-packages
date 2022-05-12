﻿# <img src="https://cdn.jsdelivr.net/gh/mkevenaar/chocolatey-packages@3559cef4d1eb00218748abd0fdf44ace62344147/icons/win32diskimager.png" width="32" height="32"/> [![Win32 Disk Imager](https://img.shields.io/chocolatey/v/win32diskimager.svg?label=Win32+Disk+Imager)](https://community.chocolatey.org/packages/win32diskimager) [![Win32 Disk Imager](https://img.shields.io/chocolatey/dt/win32diskimager.svg)](https://community.chocolatey.org/packages/win32diskimager)

## Usage

To install Win32 Disk Imager, run the following command from the command line or from PowerShell:

```powershell
choco install win32diskimager
```

To upgrade Win32 Disk Imager, run the following command from the command line or from PowerShell:

```powershell
choco upgrade win32diskimager
```

To uninstall Win32 Disk Imager, run the following command from the command line or from PowerShell:

```powershell
choco uninstall win32diskimager
```

## Description

This program is designed to write a raw disk image to removable SD or USB flash devices or backup these devices to a raw image file. It is very useful for embedded development, namely Arm development projects (Android, Ubuntu on Arm, etc). Anyone is free to branch and modify this program. Patches are always welcome.

Simply run the utility, point it at your img, and then select the removable device to write to.

This utility can not write CD-ROMs.

Warning: Issues have been reported when using to write to USB Floppy drives (and occasionally other USB devices, although very rare). It is highly recommended that before an image is written to a device, the user should do a Read to a temporary file first. If this fails, please report the failure along with your system information (file a new bug, NOT a review).

**Please Note**: This is an automatically updated package. If you find it is
out of date by more than a day or two, please contact the maintainer(s) and
let them know the package is no longer updating correctly.


## Links

[Chocolatey Package Page](https://community.chocolatey.org/packages/win32diskimager)

[Software Site](https://sourceforge.net/projects/win32diskimager/)

[Package Source](https://github.com/mkevenaar/chocolatey-packages/tree/master/automatic/win32diskimager)

