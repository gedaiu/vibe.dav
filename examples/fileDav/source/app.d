import vibe.d;

import vibedav.base;

shared static this()
{
	std.stdio.writeln("File DAV Server started on port 8080");

	auto dav = serveFileDav(Path("public/"));

	auto router = new URLRouter;
	router.any("*", serveFileDav(Path("public/")) );
	router.match(HTTPMethod.OPTIONS, "*", dav);
	router.match(HTTPMethod.PROPFIND, "*", dav);


	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	listenHTTP(settings, router);
}
