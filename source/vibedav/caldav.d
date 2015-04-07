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


interface ICalendarCollectionProperties {

	@property {
		@ResourceProperty("calendar-description", "urn:ietf:params:xml:ns:caldav")
		string calendarDescription();

		@ResourceProperty("calendar-timezone", "urn:ietf:params:xml:ns:caldav")
		TimeZone calendarTimezone();

		@ResourceProperty("supported-calendar-component-set", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyValueAttr("comp", "urn:ietf:params:xml:ns:caldav", "name")
		string[] supportedCalendarComponentSet();

		@ResourceProperty("supported-calendar-data", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagAttributes("calendar-data", "urn:ietf:params:xml:ns:caldav")
		string[string][] supportedCalendarData();

		@ResourceProperty("max-resource-size", "urn:ietf:params:xml:ns:caldav")
		ulong maxResourceSize();

		@ResourceProperty("min-date-time", "urn:ietf:params:xml:ns:caldav")
		SysTime minDateTime();

		@ResourceProperty("max-date-time", "urn:ietf:params:xml:ns:caldav")
		SysTime maxDateTime();

		@ResourceProperty("max-instances", "urn:ietf:params:xml:ns:caldav")
		ulong maxInstances();

		@ResourceProperty("max-attendees-per-instance", "urn:ietf:params:xml:ns:caldav")
		ulong maxAttendeesPerInstance();
	}
}

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
		IFileDav dav;
	}

	this(IFileDav dav, URL url, bool forceCreate = false) {
		super(dav, url, forceCreate);

		this.dav = dav;
		auto path = url.path;

		path.normalize;

		filePath = dav.filePath(url);
		nativePath = filePath.toNativeString();

		if(!forceCreate && !nativePath.exists)
			throw new DavException(HTTPStatus.notFound, "File not found.");

		href = path.toString;
	}

	override bool[string] getChildren() {
		DavResource[] list;
		string listPath = nativePath.decode;
		return getFolderContent!"*"(listPath, dav.rootFile, dav.rootUrl);
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

	this(IFileDav dav, URL url, bool forceCreate = false) {
		super(dav, url, forceCreate);

		if(forceCreate && !nativePath.exists)
			nativePath.mkdirRecurse;

		if(!nativePath.isDir)
			throw new DavException(HTTPStatus.internalServerError, nativePath ~ ": Path must be a folder.");
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

	this(IFileDav dav, URL url, bool forceCreate = false) {
		super(dav, url, forceCreate);

		if(!forceCreate && nativePath.isDir)
			throw new DavException(HTTPStatus.internalServerError, nativePath ~ ": Path must be a file.");

		if(forceCreate && !nativePath.exists)
			File(nativePath, "w");
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

@testName("factory get calendar collection")
unittest {
	"./test/admin".mkdirRecurse;

	alias T = FileDavResourceFactory!(
		"", "test",
		"",      FileDavCollection,          FileDavResource,
		":user", FileDavCalendarCollection,  FileDavCalendarResource
	);

	auto dav = new FileDav!T;
	auto res = T.Get(dav, URL("http://127.0.0.1/admin"));

	assert(res.type == "FileDavCalendarCollection");
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
