# Veeam ONE Monitor Server package parameters

## Package Parameters

The package accepts the following optional parameters:

* `/installDir` - Installs the component to the specified location. By default, _Veeam Service Provider Console_ uses the `ApplicationServer` subfolder of the `C:\Program Files\Veeam\Availability Console` folder. Example: `/installDir="C:\Veeam\"` **NOTE:** The component will be installed to the `C:\Veeam\ApplicationServer` folder.
* `/licenseFile` - Specifies a full path to the license file. For details on license requirements, see section [Licensed Objects](https://helpcenter.veeam.com/docs/vac/provider_admin/licensed_objects.html) of the Veeam Service Provider Console Guide for Service Providers. Example: `/licenseFile="C:\Users\Administrator\Desktop\license.lic"`
* `/username` - Specifies a user account under which the _Veeam Service Provider Console Services_ will run and that will be used to access _Veeam Service Provider Console_ database in the Microsoft Windows authentication mode. Example: `/username:VAC\Administrator`
* `/password` - This parameter must be used if you have specified the `/username` parameter. Specifies a password for the account under which the _Veeam Service Provider Console Services_ will run and that will be used to access _Veeam Service Provider Console_ database. Example: `/password:p@ssw0rd`
* `/create` - Create the requested user on this machine, this user will be added to the local Administrators group.
* `/sqlServer` - Specifies a Microsoft SQL server and instance on which the _Veeam Service Provider Console_ database will be deployed. By default, Veeam Service Provider Console uses the `LOCALHOST\VEEAMSQL2016` server. Example: `/sqlServer:VAC\VEEAMSQL2016_DB`
* `/sqlDatabase` - Specifies a name of the _Veeam Service Provider Console_ database, by default, `VSPC`. Example: `/sqlDatabase:VACDB`
* `/sqlAuthentication` - Specifies if you want to use the Microsoft SQL Server authentication mode to connect to the _Microsoft SQL Server_ where the _Veeam Service Provider Console_ database is deployed. Specify `1` to use the SQL Server authentication mode. If you do not use this parameter, _Veeam Service Provider Console_ will connect to the _Microsoft SQL Server_ in the Microsoft Windows authentication mode (default value, `0`). Together with this parameter, you **must** specify the following parameters: `/sqlUsername` and `/sqlPassword`. Example: `/sqlAuthentication:1`
* `/sqlUsername` - This parameter must be used if you have specified the `/sqlAuthentication` parameter. Specifies a LoginID to connect to the _Microsoft SQL Server_ in the SQL Server authentication mode. Example: `/sqlUsername:sa`
* `/sqlPassword` - This parameter must be used if you have specified the `/sqlAuthentication` parameter. Specifies a password to connect to the _Microsoft SQL Server_ in the SQL Server authentication mode. Example: `/sqlPassword:p@ssw0rd`
* `/serverManagementPort` - Specifies the port number that the _Veeam Service Provider Console Web UI_ component uses to communicate with the Server component. If you do not use this parameter, _Veeam Service Provider Console Web UI_ component will use the default port `1989`. Example: `/serverManagementPort:102`
* `/connectionHubPort` - Specifies port used to transfer traffic from cloud gateways and _Veeam Cloud Connect_ server to _Veeam Service Provider Console Server_ component. If you do not use this parameter, _Veeam Service Provider Console Web UI_ component will use the default port `9999`. Example: `/serverManagementPort:101`
* `/serverCertificateThumbprint` - Specifies a thumbprint to verify the security certificate installed on the _Veeam Service Provider Console server_. If you do not use this parameter, _Veeam Service Provider Console_ will generate a new self-signed certificate. Example: `/serverCertificateThumbprint:"028EC0FB60A7EBA9B140FCD1553061AF991A7FDE"`

Example: `choco install veeam-service-provider-console-server --params "/installdir:C:\Veeam"`
