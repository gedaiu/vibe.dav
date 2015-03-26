/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
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

class DavCalendarBaseResource : DavResource {
	protected IDav dav;

	this(IDav dav, URL url) {
		super(dav, url);
		this.dav = dav;
	}
}

/// Represents a file or directory DAV resource. NS=urn:ietf:params:xml:ns:caldav
class DavFileCalendarResource : DavCalendarBaseResource {
	alias DavFsType = DavFs!DavFileCalendarResource;

	string description; //CALDAV:calendar-description
	TimeZone timezone;  //CALDAV:calendar-timezone
	//CALDAV:supported-calendar-component-set
	//CALDAV:supported-calendar-data
    //CALDAV:max-resource-size
    SysTime minDate; //CALDAV:min-date-time
    SysTime maxDate; //CALDAV:max-date-time
    ulong maxInstances; //CALDAV:max-instances
   	ulong maxAttendeesPerInstance; //CALDAV:max-attendees-per-instance

	protected immutable Path filePath;

	this(DavFsType dav, URL url) {
		super(dav, url);
		filePath = dav.filePath(url);
	}

	override DavResource[] getChildren(ulong depth = 1) {
		throw new DavException(HTTPStatus.notImplemented, "Can not .");
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
