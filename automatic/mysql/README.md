# <img src="https://cdn.jsdelivr.net/gh/mkevenaar/chocolatey-packages@4d4a3bbed8b6b77e184e64522d9cd3247017391e/icons/mysql.png" width="48" height="48"/> [mysql](https://community.chocolatey.org/packages/mysql)

MySQL Community Edition is the freely downloadable version of the world's most popular open source database. It is available under the GPL license and is supported by a huge and active community of open source developers.

**Please Note**: This is an automatically updated package. If you find it is
out of date by more than a day or two, please contact the maintainer(s) and
let them know the package is no longer updating correctly.

### Package Parameters

The package accepts the following optional parameters:

* `/installLocation` - filesystem location for mysql binaries
* `/dataLocation` - filesystem location for mysql data
* `/port` - numberic TCP listening port
* `/serviceName` - custom name for the Windows services entry

Example: `choco install mysql --params "/port:3307 /serviceName:AltSQL"`
