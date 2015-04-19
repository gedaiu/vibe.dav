/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.caldav;

public import vibedav.base;
import vibedav.filedav;

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

/*
class DavCalendarBaseResource : DavResource, ICalendarCollectionProperties, IDavResourceExtendedProperties {
	protected IDav dav;

	this(IDav dav, URL url, bool forceCreate = false) {
		super(dav, url);

		this.dav = dav;
	}

	@property {
		override string[] extraSupport() {
			string[] headers = ["access-control", "calendar-access"];
			return headers;
		}

		string calendarDescription() {
			return name;
		}

		TimeZone calendarTimezone() {
			TimeZone t;
			return t;
		}

		string[] supportedCalendarComponentSet() {
			return ["VEVENT", "VTODO", "VJOURNAL", "VFREEBUSY", "VTIMEZONE", "VALARM"];
		}

		string[string][] supportedCalendarData() {
			string[string][] list;

			list ~= [["content-type": "text/calendar", "version": "2.0"]];

			return list;
		}

		ulong maxResourceSize() {
			return ulong.max;
		}

		SysTime minDateTime() {
			return SysTime.min;
		}

		SysTime maxDateTime() {
			return SysTime.max;
		}

		ulong maxInstances() {
			return ulong.max;
		}

		ulong maxAttendeesPerInstance() {
			return ulong.max;
		}

		string[] addMember() {
			return [href];
		}

		string owner() {
			if(user is null)
				return "";

			return user.principalURL;
		}
	}
}

/// Represents a file or directory DAV resource. NS=urn:ietf:params:xml:ns:caldav
class DavFileBaseCalendarResource : DavCalendarBaseResource {

	protected {
		immutable Path filePath;
		immutable string nativePath;
		IDav dav;
		IFileDav davPlugin;
	}

	this(IFileDav davPlugin, URL url, bool forceCreate = false) {
		super(davPlugin.dav, url, forceCreate);

		this.dav = dav;
		this.davPlugin = davPlugin;
		auto path = url.path;

		path.normalize;

		filePath = davPlugin.filePath(url);
		nativePath = filePath.toNativeString();

		if(!forceCreate && !nativePath.exists)
			throw new DavException(HTTPStatus.notFound, "File not found.");

		href = path.toString;
	}

	@property {

		string eTag() {
			return nativePath.eTag;
		}

		SysTime creationDate() {
			return nativePath.creationDate;
		}

		SysTime lastModified() {
			return nativePath.lastModified;
		}

		override bool isCollection() {
			return nativePath.isDir;
		}
	}
}

class FileDavCalendarCollection : DavFileBaseCalendarResource {

	this(IFileDav davPlugin, URL url, bool forceCreate = false) {
		super(davPlugin, url, forceCreate);

		if(forceCreate && !nativePath.exists)
			nativePath.mkdirRecurse;

		if(!nativePath.isDir)
			throw new DavException(HTTPStatus.internalServerError, nativePath ~ ": Path must be a folder.");
	}

	override bool[string] getChildren() {
		DavResource[] list;
		string listPath = nativePath.decode;
		return getFolderContent!"*.ics"(listPath, davPlugin.rootFile, dav.rootUrl);
	}

	@property {
		ulong contentLength() {
			return 0;
		}

		string contentType() {
			return "text/directory";
		}

		string[] resourceType() {
			return ["collection:DAV:", "calendar:urn:ietf:params:xml:ns:caldav"];
		}

		override {
			InputStream stream() {
				throw new DavException(HTTPStatus.internalServerError, "can't get stream from folder.");
			}

			string type() {
				return "FileDavCalendarCollection";
			}
		}
	}

	override {
		void setContent(const ubyte[] content) {
			throw new DavException(HTTPStatus.internalServerError, "can't set content for collection.");
		}

		void setContent(InputStream content, ulong size) {
			throw new DavException(HTTPStatus.internalServerError, "can't set content for collection.");
		}
	}
}

/// Represents a file or directory DAV resource. NS=urn:ietf:params:xml:ns:caldav
class FileDavCalendarResource : DavFileBaseCalendarResource {

	this(IFileDav davPlugin, URL url, bool forceCreate = false) {
		super(davPlugin, url, forceCreate);

		if(!forceCreate && nativePath.isDir)
			throw new DavException(HTTPStatus.internalServerError, nativePath ~ ": Path must be a file.");

		if(forceCreate && !nativePath.exists)
			File(nativePath, "w");
	}

	override bool[string] getChildren() {
		bool[string] list;
		return list;
	}

	@property {
		ulong contentLength() {
			return nativePath.contentLength;
		}

		string contentType() {
			return getMimeTypeForFile(nativePath);
		}

		string[] resourceType() {
			return ["calendar:urn:ietf:params:xml:ns:caldav"];
		}

		override {
			InputStream stream() {
				return nativePath.toStream;
			}

			string type() {
				return "FileDavCalendarCollection";
			}
		}
	}

	override {
		DavProp property(string key) {
			if(hasDavInterfaceProperty!ICalendarCollectionProperties(key))
				return getDavInterfaceProperty!ICalendarCollectionProperties(key, this);

			if(hasDavInterfaceProperty!IDavResourceExtendedProperties(key))
				return getDavInterfaceProperty!IDavResourceExtendedProperties(key, this);

			return super.property(key);
		}

		void setContent(const ubyte[] content) {
			std.stdio.write(nativePath, content);
		}

		void setContent(InputStream content, ulong size) {
			if(nativePath.isDir)
				throw new DavException(HTTPStatus.conflict, "");

			auto tmpPath = filePath.to!string ~ ".tmp";
			auto tmpFile = File(tmpPath, "w");

			while(!content.empty) {
				auto leastSize = content.leastSize;
				ubyte[] buf;
				buf.length = leastSize;
				content.read(buf);
				tmpFile.rawWrite(buf);
			}

			tmpFile.flush;
			std.file.copy(tmpPath, nativePath);
			std.file.remove(tmpPath);
		}

		void remove() {
			super.remove;
			nativePath.remove;
		}
	}
}

class BaseCalDavUser : ICalDavUser, IDavUser {

	immutable string name;

	this(const string name) {
		this.name = name;
	}

	pure {
		@property {
			string currentUserPrincipal() {
				return "/calendar/"~name~"/";
			}

			string[] principalCollectionSet() {
				return ["/calendar/"];
			}

			string principalURL() {
				return currentUserPrincipal;
			}

			string[] calendarHomeSet() {
				return ["/calendar/"~name~"/"];
			}

			string[] calendarUserAddressSet() {
				return [];
			}

			string scheduleInboxURL() {
				return "/calendar/"~name~"/inbox/";
			}

			string scheduleOutboxURL()  {
				return "/calendar/"~name~"/outbox/";
			}
		}

		bool hasProperty(string name) {
			return hasDavInterfaceProperty!ICalDavUser(name);
		}
	}

	DavProp property(string name) {
		return getDavInterfaceProperty!ICalDavUser(name, this);
	}
}


class BaseCalDavUserCollection : IDavUserCollection {
	IDavUser GetDavUser(const string name) {
		return new BaseCalDavUser(name);
	}
}
*/

private bool matchPluginUrl(URL url, string username) {
	if(username == "")
		return false;

	string path = url.path.toString;

	string calendarsPath = "/principals/" ~ username ~ "/";
	auto len = calendarsPath.length;

	if(path.length >= len && path[0..len] == calendarsPath)
		return true;

	return false;
}

class CalDavResourcePlugin : IDavResourcePlugin, ICalDavProperties, IDavReportSetProperties {

	string[] calendarHomeSet(DavResource resource) {
		if(matchPluginUrl(resource.url, resource.username))
			return ["/principals/" ~ resource.username ~ "/calendars"];

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string scheduleOutboxURL(DavResource resource) {
		if(matchPluginUrl(resource.url, resource.username))
			return "/principals/" ~ resource.username ~ "/outbox";

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string scheduleInboxURL(DavResource resource) {
		if(matchPluginUrl(resource.url, resource.username))
			return "/principals/" ~ resource.username ~ "/inbox";

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string[] calendarUserAddressSet(DavResource resource) {
		if(matchPluginUrl(resource.url, resource.username))
			return [ "mailto:" ~ resource.username ~ "@local.com" ];

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string[] supportedReportSet(DavResource resource) {
		if(matchPluginUrl(resource.url, resource.username))
			return ["free-busy-query:DAV:", "calendar-query:DAV:", "calendar-multiget:DAV:"];

		return [];
	}

	bool canSetContent(DavResource resource) {
		return false;
	}

	bool canGetStream(DavResource resource) {
		return false;
	}

	bool canSetProperty(DavResource resource, string name) {
		return false;
	}

	bool canRemoveProperty(DavResource resource, string name) {
		return false;
	}

	bool canGetProperty(DavResource resource, string name) {
		if(matchPluginUrl(resource.url, resource.username) && hasDavInterfaceProperty!ICalDavProperties(name))
			return true;

		if(matchPluginUrl(resource.url, resource.username) && hasDavInterfaceProperty!IDavReportSetProperties(name))
			return true;

		return false;
	}

	bool[string] getChildren(DavResource resource) {
		bool[string] list;
		return list;
	}

	void setContent(DavResource resource, const ubyte[] content) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set content.");
	}

	void setContent(DavResource resource, InputStream content, ulong size) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set content.");
	}

	InputStream stream(DavResource resource) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get stream.");
	}

	void copyPropertiesTo(URL source, URL destination) { }

	DavProp property(DavResource resource, string name) {
		if(!matchPluginUrl(resource.url, resource.username))
			throw new DavException(HTTPStatus.internalServerError, "Can't get property.");

		if(hasDavInterfaceProperty!ICalDavProperties(name))
			return getDavInterfaceProperty!ICalDavProperties(name, this, resource);

		if(hasDavInterfaceProperty!IDavReportSetProperties(name))
			return getDavInterfaceProperty!IDavReportSetProperties(name, this, resource);

		throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
	}

	HTTPStatus setProperty(DavResource resource, string name, DavProp prop) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set property.");
	}

	HTTPStatus removeProperty(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove property.");
	}

	@property {
		string name() {
			return "ResourceBasicProperties";
		}
	}
}

class CalDavPlugin : IDavPlugin {

	private IDav _dav;

	this(IDav dav) {
		_dav = dav;
	}

	bool exists(URL url, string username) {
		return false;
	}

	bool canCreateCollection(URL url, string username) {
		return false;
	}

	bool canCreateResource(URL url, string username) {
		return false;
	}

	void removeResource(URL url, string username) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove resource.");
	}

	DavResource getResource(URL url, string username) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get resource.");
	}

	DavResource createCollection(URL url, string username) {
		throw new DavException(HTTPStatus.internalServerError, "Can't create collection.");
	}

	DavResource createResource(URL url, string username) {
		throw new DavException(HTTPStatus.internalServerError, "Can't create resource.");
	}

	void bindResourcePlugins(ref DavResource resource) {
		resource.registerPlugin(new CalDavResourcePlugin);
	}

	@property {
		IDav dav() {
			return _dav;
		}

		string name() {
			return "CalDavPlugin";
		}

		string[] support(URL url, string username) {
			if(matchPluginUrl(url, username))
				return [ "calendar-access" ];

			return [];
		}
	}
}

