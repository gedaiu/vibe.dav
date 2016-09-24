/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 13, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
import vibe.http.router : URLRouter;
import vibe.http.server;
import vibe.http.auth.basic_auth;

import vibedav.plugins.filedav;
import vibedav.plugins.acldav;
import vibedav.plugins.caldav;
import vibedav.plugins.syncdav;

import core.time;
import std.stdio;
import std.functional : toDelegate;

bool checkPassword(string user, string password)
{
	writeln("user: ", user, " pass: ", password);
	return user == "admin" && password == "secret";
}

shared static this()
{
	writeln("Start Kangal server");

	auto router = new URLRouter;

	// now any request is matched and checked for authentication:
	router.any("/principals/*", performBasicAuth("Site Realm", toDelegate(&checkPassword)));

	auto dav = router.serveFileDav("", "public");

	new ACLDavPlugin(dav);
	new CalDavPlugin(dav);
	new SyncDavPlugin(dav);

	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1","0.0.0.0", "192.168.0.13", "192.168.0.100"];
	listenHTTP(settings, router);
}
