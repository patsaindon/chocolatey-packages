﻿# <img src="https://cdn.jsdelivr.net/gh/mkevenaar/chocolatey-packages@51247a81a30c4c8d14434fcbc61c7a0b750c0945/icons/winrar.png" width="32" height="32"/> [![WinRAR](https://img.shields.io/chocolatey/v/winrar.svg?label=WinRAR)](https://community.chocolatey.org/packages/winrar) [![WinRAR](https://img.shields.io/chocolatey/dt/winrar.svg)](https://community.chocolatey.org/packages/winrar)

## Usage

To install WinRAR, run the following command from the command line or from PowerShell:

```powershell
choco install winrar
```

To upgrade WinRAR, run the following command from the command line or from PowerShell:

```powershell
choco upgrade winrar
```

To uninstall WinRAR, run the following command from the command line or from PowerShell:

```powershell
choco uninstall winrar
```

## Description

**NOTE** When a new version is released, not all translations are avaialbe. Currently there is no solution to permanently fix this. For more information have a look at issue [#20](https://github.com/mkevenaar/chocolatey-packages/issues/20)

## WinRAR

WinRAR is a powerful archive manager. It can backup your data and reduce the size of email attachments, decompress RAR, ZIP and other files downloaded from Internet and create new archives in RAR and ZIP file format.

You can find themes for WinRAR [here](http://www.rarlab.com/themes.htm).

### Commercial software

You can try WinRAR before you [buy](https://shop.win-rar.com/16/purl-shop-1984-1-n).

### Package Parameters

The following package parameters can be set:

* `/LCID:` - the language code you want to install - defaults to your current language
* `/English:` - force English language to install

To pass parameters, use `--params "''"` (e.g. `choco install packageID [other options] --params="'/ITEM:value /ITEM2:value2 /FLAG_BOOLEAN'"`).
To have choco remember parameters on upgrade, be sure to set `choco feature enable -n=useRememberedArgumentsForUpgrades`.

**Please Note**: This is an automatically updated package. If you find it is
out of date by more than a day or two, please contact the maintainer(s) and
let them know the package is no longer updating correctly.


## Links

[Chocolatey Package Page](https://community.chocolatey.org/packages/winrar)

[Software Site](http://www.win-rar.com/)

[Package Source](https://github.com/mkevenaar/chocolatey-packages/tree/master/automatic/winrar)

