/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.plugins.caldav;

public import vibedav.base;
import vibedav.plugins.filedav;
import vibedav.plugins.syncdav;

import vibe.core.file;
import vibe.http.server;
import vibe.inet.mimetypes;
import vibe.inet.message;

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

private bool matchPluginUrl(Path path, string username) {
	if(path.length < 2) {
		return false;
	}

	if(path[0] != "principals") {
		return false;
	}

	if(path[1] != username) {
		return false;
	}

	return true;
}

interface ICalDavProperties {
	@property {

		/// rfc4791 - 6.2.1
		@ResourceProperty("calendar-home-set", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagText("href", "DAV:")
		string[] calendarHomeSet(DavResource resource);

		///rfc6638 - 2.1.1
		@ResourceProperty("schedule-outbox-URL", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagText("href", "DAV:")
		string scheduleOutboxURL(DavResource resource);

		/// rfc6638 - 2.2.1
		@ResourceProperty("schedule-inbox-URL", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagText("href", "DAV:")
		string scheduleInboxURL(DavResource resource);

		/// rfc6638 - 2.4.1
		@ResourceProperty("calendar-user-address-set", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagText("href", "DAV:")
		string[] calendarUserAddressSet(DavResource resource);
	}
}

interface ICalDavCollectionProperties {

	@property {
		@ResourceProperty("calendar-description", "urn:ietf:params:xml:ns:caldav")
		string calendarDescription(DavResource resource);

		@ResourceProperty("calendar-timezone", "urn:ietf:params:xml:ns:caldav")
		TimeZone calendarTimezone(DavResource resource);

		@ResourceProperty("supported-calendar-component-set", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyValueAttr("comp", "urn:ietf:params:xml:ns:caldav", "name")
		string[] supportedCalendarComponentSet(DavResource resource);

		@ResourceProperty("supported-calendar-data", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagAttributes("calendar-data", "urn:ietf:params:xml:ns:caldav")
		string[string][] supportedCalendarData(DavResource resource);

		@ResourceProperty("max-resource-size", "urn:ietf:params:xml:ns:caldav")
		ulong maxResourceSize(DavResource resource);

		@ResourceProperty("min-date-time", "urn:ietf:params:xml:ns:caldav")
		SysTime minDateTime(DavResource resource);

		@ResourceProperty("max-date-time", "urn:ietf:params:xml:ns:caldav")
		SysTime maxDateTime(DavResource resource);

		@ResourceProperty("max-instances", "urn:ietf:params:xml:ns:caldav")
		ulong maxInstances(DavResource resource);

		@ResourceProperty("max-attendees-per-instance", "urn:ietf:params:xml:ns:caldav")
		ulong maxAttendeesPerInstance(DavResource resource);
	}
}

interface ICalDavResourceProperties {

	@property {
		@ResourceProperty("calendar-data", "urn:ietf:params:xml:ns:caldav")
		string calendarData(DavResource resource);
	}
}

interface ICalDavReports {
	@DavReport("free-busy-query", "urn:ietf:params:xml:ns:caldav")
	void freeBusyQuery(DavRequest request, DavResponse response);

	@DavReport("calendar-query", "urn:ietf:params:xml:ns:caldav")
	void calendarQuery(DavRequest request, DavResponse response);

	@DavReport("calendar-multiget", "urn:ietf:params:xml:ns:caldav")
	void calendarMultiget(DavRequest request, DavResponse response);
}

interface ICalDavSchedulingProperties {

	// for Inbox
	//<schedule-default-calendar-URL xmlns="urn:ietf:params:xml:ns:caldav" />

	/*
    <default-alarm-vevent-date xmlns="urn:ietf:params:xml:ns:caldav" />
    <default-alarm-vevent-datetime xmlns="urn:ietf:params:xml:ns:caldav" />
    <supported-calendar-component-sets xmlns="urn:ietf:params:xml:ns:caldav" />
    <schedule-calendar-transp xmlns="urn:ietf:params:xml:ns:caldav" />
    <calendar-free-busy-set xmlns="urn:ietf:params:xml:ns:caldav" />*/
}

class CalDavDataPlugin : BaseDavResourcePlugin, ICalDavProperties, IDavReportSetProperties, IDavBindingProperties {

	string[] calendarHomeSet(DavResource resource) {

		if(matchPluginUrl(resource.path, resource.username))
			return [ "/" ~ resource.rootURL ~"principals/" ~ resource.username ~ "/calendars/" ];

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string scheduleOutboxURL(DavResource resource) {
		if(matchPluginUrl(resource.path, resource.username))
			return "/" ~ resource.rootURL ~"principals/" ~ resource.username ~ "/outbox/";

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string scheduleInboxURL(DavResource resource) {
		if(matchPluginUrl(resource.path, resource.username))
			return "/" ~ resource.rootURL ~"principals/" ~ resource.username ~ "/inbox/";

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string[] calendarUserAddressSet(DavResource resource) {
		if(matchPluginUrl(resource.path, resource.username))
			return [ "mailto:" ~ resource.username ~ "@local.com" ];

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string[] supportedReportSet(DavResource resource) {
		if(matchPluginUrl(resource.path, resource.username))
			return ["free-busy-query:urn:ietf:params:xml:ns:caldav", "calendar-query:urn:ietf:params:xml:ns:caldav", "calendar-multiget:urn:ietf:params:xml:ns:caldav"];

		return [];
	}

	string resourceId(DavResource resource) {
		return resource.eTag;
	}

	override {
		bool canGetProperty(DavResource resource, string name) {
			if(!matchPluginUrl(resource.path, resource.username))
				return false;

			if(hasDavInterfaceProperty!ICalDavProperties(name))
				return true;

			if(hasDavInterfaceProperty!IDavReportSetProperties(name))
				return true;

			if(hasDavInterfaceProperty!IDavBindingProperties(name))
				return true;

			return false;
		}

		DavProp property(DavResource resource, string name) {
			if(!matchPluginUrl(resource.path, resource.username))
				throw new DavException(HTTPStatus.internalServerError, "Can't get property.");

			if(hasDavInterfaceProperty!ICalDavProperties(name))
				return getDavInterfaceProperty!ICalDavProperties(name, this, resource);

			if(hasDavInterfaceProperty!IDavReportSetProperties(name))
				return getDavInterfaceProperty!IDavReportSetProperties(name, this, resource);

			if(hasDavInterfaceProperty!IDavBindingProperties(name))
				return getDavInterfaceProperty!IDavBindingProperties(name, this, resource);

			throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
		}
	}

	@property {
		string name() {
			return "CalDavDataPlugin";
		}
	}
}

class CalDavResourcePlugin : BaseDavResourcePlugin, ICalDavResourceProperties {
	string calendarData(DavResource resource) {

		auto content = resource.stream;
		string data;

		while(!content.empty) {
			auto leastSize = content.leastSize;
			ubyte[] buf;

			buf.length = leastSize;
			content.read(buf);

			data ~= buf;
		}

		return data;
	}

	override {

		bool canGetProperty(DavResource resource, string name) {
			if(matchPluginUrl(resource.path, resource.username) && hasDavInterfaceProperty!ICalDavResourceProperties(name))
				return true;

			return false;
		}

		DavProp property(DavResource resource, string name) {
			if(!matchPluginUrl(resource.path, resource.username))
				throw new DavException(HTTPStatus.internalServerError, "Can't get property.");

			if(hasDavInterfaceProperty!ICalDavResourceProperties(name))
				return getDavInterfaceProperty!ICalDavResourceProperties(name, this, resource);

			throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
		}
	}


	@property {
		string name() {
			return "CalDavResourcePlugin";
		}
	}
}

class CalDavCollectionPlugin : BaseDavResourcePlugin, ICalDavCollectionProperties {

	string calendarDescription(DavResource resource) {
		return resource.name;
	}

	TimeZone calendarTimezone(DavResource resource) {
		TimeZone t;
		return t;
	}

	string[] supportedCalendarComponentSet(DavResource resource) {
		return ["VEVENT", "VTODO", "VJOURNAL", "VFREEBUSY", "VTIMEZONE", "VALARM"];
	}

	string[string][] supportedCalendarData(DavResource resource) {
		string[string][] list;

		list ~= [["content-type": "text/calendar", "version": "2.0"]];

		return list;
	}

	ulong maxResourceSize(DavResource resource) {
		return ulong.max;
	}

	SysTime minDateTime(DavResource resource) {
		return SysTime.min;
	}

	SysTime maxDateTime(DavResource resource) {
		return SysTime.max;
	}

	ulong maxInstances(DavResource resource) {
		return ulong.max;
	}

	ulong maxAttendeesPerInstance(DavResource resource) {
		return ulong.max;
	}

	override {

		bool canGetProperty(DavResource resource, string name) {
			if(matchPluginUrl(resource.path, resource.username) && hasDavInterfaceProperty!ICalDavCollectionProperties(name))
				return true;

			return false;
		}

		DavProp property(DavResource resource, string name) {
			if(!matchPluginUrl(resource.path, resource.username))
				throw new DavException(HTTPStatus.internalServerError, "Can't get property.");

			if(hasDavInterfaceProperty!ICalDavCollectionProperties(name))
				return getDavInterfaceProperty!ICalDavCollectionProperties(name, this, resource);

			throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
		}
	}

	@property {
		string name() {
			return "CalDavCollectionPlugin";
		}
	}
}

class CalDavPlugin : BaseDavPlugin, ICalDavReports {

	this(IDav dav) {
		super(dav);
	}

	bool isCalendarsCollection(Path path, string username) {
		if(!matchPluginUrl(path, username))
			return false;

		return path.length == 3 && path[2] == "calendars";
	}

	bool isPrincipalCollection(Path path, string username) {
		if(!matchPluginUrl(path, username))
			return false;

		return path.length == 2;
	}

	override {
		bool exists(URL url, string username) {
			return isCalendarsCollection(dav.path(url), username);
		}

		Path[] childList(URL url, string username) {
			if (isPrincipalCollection(dav.path(url), username)) {
				return [ Path("principals/" ~ username ~ "/calendars/") ];
			}

			return [];
		}

		DavResource getResource(URL url, string username) {
			if(isCalendarsCollection(dav.path(url), username)) {
				DavResource resource = super.getResource(url, username);
				resource.resourceType ~= "collection:DAV:";

				return resource;
			}

			throw new DavException(HTTPStatus.internalServerError, "Can't get resource.");
		}

		void bindResourcePlugins(DavResource resource) {
			if(!matchPluginUrl(resource.path, resource.username))
				return;

			resource.registerPlugin(new CalDavDataPlugin);
			auto path = resource.url.path.toString.stripSlashes;

			if(resource.isCollection && path != "principals/" ~ resource.username ~ "/calendars") {
				resource.resourceType ~= "calendar:urn:ietf:params:xml:ns:caldav";
				resource.registerPlugin(new CalDavCollectionPlugin);
			} else if(!resource.isCollection && path.length > 4 && path[$-4..$].toLower == ".ics") {
				resource.registerPlugin(new CalDavResourcePlugin);
			}
		}

		bool hasReport(URL url, string username, string name) {

			if(!matchPluginUrl(dav.path(url), username))
				return false;

			if(hasDavReport!ICalDavReports(name))
				return true;

			return false;
		}

		void report(DavRequest request, DavResponse response) {
			if(!matchPluginUrl(dav.path(request.url), request.username) || !hasDavReport!ICalDavReports(request.content.reportName))
				throw new DavException(HTTPStatus.internalServerError, "Can't get report.");

			getDavReport!ICalDavReports(this, request, response);
		}
	}

	void freeBusyQuery(DavRequest request, DavResponse response) {
		throw new DavException(HTTPStatus.internalServerError, "Not Implemented");
	}

	void calendarQuery(DavRequest request, DavResponse response) {
		throw new DavException(HTTPStatus.internalServerError, "Not Implemented");
	}

	void calendarMultiget(DavRequest request, DavResponse response) {
		response.mimeType = "application/xml";
		response.statusCode = HTTPStatus.multiStatus;
		auto reportData = request.content;

		bool[string] requestedProperties;

		foreach(name, p; reportData["calendar-multiget"]["prop"])
			requestedProperties[name] = true;

		DavResource[] list;

		auto hrefList = [ reportData["calendar-multiget"] ].getTagChilds("href");

		HTTPStatus[string] resourceStatus;

		foreach(p; hrefList) {
			string path = p.value;

			try {
				list ~= dav.getResource(URL(path), request.username);
				resourceStatus[path] = HTTPStatus.ok;
			} catch(DavException e) {
				resourceStatus[path] = e.status;
			}
		}

		response.setPropContent(list, requestedProperties, resourceStatus);
		response.flush;
	}

	@property {

		string name() {
			return "CalDavPlugin";
		}

		override string[] support(URL url, string username) {
			if(matchPluginUrl(dav.path(url), username))
				return [ "calendar-access" ];

			return [];
		}
	}
}
