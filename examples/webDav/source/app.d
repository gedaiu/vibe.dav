/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 13, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
import vibe.core.file;
import vibe.core.log;
import vibe.inet.message;
import vibe.inet.mimetypes;
import vibe.http.router : URLRouter;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.auth.basic_auth;

import vibedav.filedav;
import vibedav.caldav;
import vibedav.user;
import vibedav.prop;
import vibedav.userhome;

import core.time;
import std.conv : to;
import std.stdio;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.functional : toDelegate;

bool checkPassword(string user, string password)
{
	return user == "admin" && password == "secret";
}

shared static this()
{
	writeln("Starting WebDav server.");

	auto router = new URLRouter;

	// now any request is matched and checked for authentication:
	router.any("/calendar/*", performBasicAuth("Site Realm", toDelegate(&checkPassword)));

	auto userConnection = new BaseCalDavUserCollection;

	alias factory = FileDavResourceFactory!(
		"calendar", "public/calendar",
		"",               FileDavCollection,         FileDavResource,
		":user/",         FileDavCollection,         FileDavResource,
		":user/inbox",    FileDavCollection,         FileDavResource,
		":user/outbox",   FileDavCollection,         FileDavResource,
		":user/personal", FileDavCalendarCollection, FileDavCalendarResource
	);

	router.serveFileDav!("/files/", "public/files/")(userConnection);
	router.serveFileDav!factory(userConnection);

	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	listenHTTP(settings, router);
}
