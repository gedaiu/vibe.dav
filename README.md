# Vibe.Dav

A library that adds DAV support to vibe.d

## Support

FileDav with locking
CalDav with basic support
CardDav no support

## How to use

### FileDav

Use 

	void serveFileDav(string rootUrl, string rootPath)(URLRouter router, IDavUserCollection userCollection) 
	
to bind the fileDav handlers to a vibe router.

The next exemple will map every resource from `http://localhost/files` to `public/files`
	
	import vibedav.filedav;
	
	...
	
	auto router = new URLRouter;
	router.serveFileDav!("/files/", "public/files/")(userConnection);
	
	...
	
	listenHTTP(settings, router);  

### CalDav

Use the factory class that maps resource types to url nodes:

	alias T = FileDavResourceFactory!(
		[rootUrl], [rootPath],
		
		[nodeUrl], [collection type], [resource type]
		...
	);
	
	
Example of maping a simple cal dav folder structure (more work will be done here):

auto router = new URLRouter;

	// Do some basic auth
	router.any("/calendar/*", performBasicAuth("Site Realm", toDelegate(&checkPassword)));

	// Create a basic user collection, used to manage CalDav users
	auto userConnection = new BaseCalDavUserCollection;

	// Create a custom file maping
	alias factory = FileDavResourceFactory!(
		
		// map "http://127.0.0.1/calendar" to "public/calendar"
		"calendar", "public/calendar", 
		
		// map any folder to `FileDavCollection` and file to `FileDavResource`
		"",               FileDavCollection,         FileDavResource,
		
		// map the `personal` folder from users home
		// to `FileDavCalendarCollection` and files to `FileDavCalendarResource`
		":user/personal", FileDavCalendarCollection, FileDavCalendarResource
	);

	// Bind the custom FileDav maping to a vibe router.
	router.serveFileDav!factory(userConnection);
	
	...
	
	listenHTTP(settings, router);


