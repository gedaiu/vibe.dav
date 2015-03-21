/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.caldav;

public import vibedav.base;

import vibe.core.file;
import vibe.http.server;

import std.conv : to;
import std.algorithm;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.string;
import std.stdio;
import std.typecons;
import std.uri;
import std.uuid;

import tested;

/// File dav impplementation
class CalDav : Dav {
	protected {
		Path rootFile;
	}

	this() {
		this("", "");
	}

	this(string rootUrl, string rootFile) {
		super(rootUrl);
		this.rootFile = Path(rootFile);
	}

	override DavResource getResource(URL url) {

		return new DavCalendarResource(this, url);
	}

	override DavResource createCollection(URL url) {

		return new DavCalendarResource(this, url);
	}

	override DavResource createProperty(URL url) {

		return new DavCalendarResource(this, url);
	}

	override void options(DavRequest request, DavResponse response) {
		super.options(request, response);
		string path = request.path;

		response["DAV"] = response["DAV"] ~ ",calendar-access";
		response["Allow"] = response["Allow"] ~ ",REPORT,ACL";

		response.flush;
	}
}

class CalDavFile : CalDav {

	this(string rootUrl, string rootFile) {
		super(rootUrl, rootFile);
	}

	override DavResource getResource(URL url) {

		return new DavCalendarResource(this, url);
	}

	override DavResource createCollection(URL url) {

		return new DavCalendarResource(this, url);
	}

	override DavResource createProperty(URL url) {

		return new DavCalendarResource(this, url);
	}
}

class DavCalendarBaseResource : DavResource {
	protected CalDav dav;

	this(CalDav dav, URL url) {
		super(dav, url);
		this.dav = dav;
	}

	override {
		DavProp property(string key) {
			switch(key) {
				default:
					return super.property(key);
				case "calendar-home-set:urn:ietf:params:xml:ns:caldav":
					return new DavProp( "urn:ietf:params:xml:ns:caldav", "calendar-home-set", homeSet);
			}
		}
	}

	@property {
		string homeSet() {
			return (dav.rootUrl ~ username).to!string;
		}
	}
}

/// Represents a file or directory DAV resource. NS=urn:ietf:params:xml:ns:caldav
class DavCalendarResource : DavCalendarBaseResource {

	string description; //CALDAV:calendar-description
	TimeZone timezone;  //CALDAV:calendar-timezone
	//CALDAV:supported-calendar-component-set
	//CALDAV:supported-calendar-data
    //CALDAV:max-resource-size
    SysTime minDate; //CALDAV:min-date-time
    SysTime maxDate; //CALDAV:max-date-time
    ulong maxInstances; //CALDAV:max-instances
   	ulong maxAttendeesPerInstance; //CALDAV:max-attendees-per-instance

	this(CalDav dav, URL url) {
		super(dav, url);
	}

	override DavResource[] getChildren(ulong depth = 1) {
		throw new DavException(HTTPStatus.notImplemented, "Can not .");
	}

	override HTTPStatus move(URL newPath, bool overwrite = false) {
		throw new DavException(HTTPStatus.notImplemented, "not notImplemented");
	}

	override void setContent(const ubyte[] content) {
		throw new DavException(HTTPStatus.notImplemented, "not notImplemented");
	}

	override void setContent(InputStream content, ulong size) {
		throw new DavException(HTTPStatus.notImplemented, "not notImplemented");
	}

	@property override {
		string eTag() {
			throw new DavException(HTTPStatus.notImplemented, "not notImplemented");
		}

		string mimeType() {
			throw new DavException(HTTPStatus.notImplemented, "not notImplemented");
		}

		SysTime lastModified() {
			throw new DavException(HTTPStatus.notImplemented, "not notImplemented");
		}

		ulong contentLength() {
			throw new DavException(HTTPStatus.notImplemented, "not notImplemented");
		}

		InputStream stream() {
			throw new DavException(HTTPStatus.notImplemented, "not notImplemented");
		}
	}
}

/// Create a cal dav server that serves the files on hdd
void serveCalDavFile(URLRouter router, string rootUrl, string rootPath) {
	CalDavFile calDav = new CalDavFile(rootUrl, rootPath);
	router.any(rootUrl ~ "*", serveDav(calDav));
}

