# Vibe.Dav

A library that adds DAV support to vibe.d

## Support

FileDav with locking
CalDav with basic support
CardDav no support

## How to use

### FileDav

Use

	IDav serveFileDav(URLRouter router, string rootUrl, string rootPath);

to bind the fileDav handlers to a vibe router.

The next exemple will map every resource from `http://localhost/files` to `public/files`

	import vibedav.filedav;

	...

	auto router = new URLRouter;
	router.serveFileDav("", "public");

	...

	listenHTTP(settings, router);

### CalDav


Example of maping a simple cal dav folder structure:

	auto router = new URLRouter;

	// Do some basic auth
	router.any("/calendar/*", performBasicAuth("Site Realm", toDelegate(&checkPassword)));

	// Bind the public folder to a vibe router.
	auto dav = router.serveFileDav("", "public");

	new ACLDavPlugin(dav); // add ACL support to the DAV instance
	new CalDavPlugin(dav); // create and bind the CalDav plugin to the DAV instance
	new SyncDavPlugin(dav); // create and bind the sync plugin to the DAV instance

	...

	listenHTTP(settings, router);



## Future development

* CardDav support
* Move the logic from the DAV class to other plugins
* Improve XML support (eg: change xml node format from "name:DAV:" to "{DAV:}name")
* Add DB support
* Add migration tools from https://github.com/Kozea/Radicale
* Maybe update the @ResourceProperty... Structs to something more general like @ResourceProperty!"<tag>%value</tag>"()
