/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 15, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.base;

public import vibedav.prop;
public import vibedav.ifheader;
public import vibedav.locks;
public import vibedav.http;
public import vibedav.davresource;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
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
import tested;

class DavStorage {
	static {
		DavLockList locks;
	}
}

class DavException : Exception {
	HTTPStatus status;
	string mime;

	///
	this(HTTPStatus status, string msg, string mime = "plain/text", string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super(msg, file, line, next);
		this.status = status;
		this.mime = mime;
	}

	///
	this(HTTPStatus status, string msg, Throwable next, string mime = "plain/text", string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, next, file, line);
		this.status = status;
		this.mime = mime;
	}
}

struct DavReport {
	string name;
	string ns;
}

string reportName(DavProp reportBody) {
	if(reportBody[0].name == "?xml")
		return reportBody[1].tagName ~ ":" ~ reportBody[1].namespace;

	return reportBody[0].tagName ~ ":" ~ reportBody[0].namespace;
}

DavReport getReportProperty(T...)() {
	static if(T.length == 0)
		static assert(false, "There is no `@DavReport` attribute.");
	else static if( is(typeof(T[0]) == DavReport) )
		return T[0];
	else
		return getResourceProperty!(T[1..$]);
}

bool hasDavReport(I)(string key) {
	bool result = false;

	void keyExist(T...)() {
		static if(T.length > 0) {
			enum val = getReportProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum staticKey = val.name ~ ":" ~ val.ns;

			if(staticKey == key)
				result = true;

			keyExist!(T[1..$])();
		}
	}

	keyExist!(__traits(allMembers, I))();

	return result;
}

void getDavReport(I)(I plugin, DavRequest request, DavResponse response) {
	string key = request.content.reportName;

	void getProp(T...)() {
		static if(T.length > 0) {
			enum val = getReportProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum staticKey = val.name ~ ":" ~ val.ns;


			if(staticKey == key) {
				__traits(getMember, plugin, T[0])(request, response);
			}

			getProp!(T[1..$])();
		}
	}

	getProp!(__traits(allMembers, I))();
}

interface IDavResourceAccess {
	bool exists(URL url, string username);
	bool canCreateCollection(URL url, string username);
	bool canCreateResource(URL url, string username);

	void removeResource(URL url, string username);
	DavResource getResource(URL url, string username);
	DavResource createCollection(URL url, string username);
	DavResource createResource(URL url, string username);

	void bindResourcePlugins(DavResource resource);
}

interface IDavPlugin : IDavResourceAccess {

	bool hasReport(URL url, string username, string name);
	void report(DavRequest request, DavResponse response);

	void notice(string action, DavResource resource);

	@property {
		IDav dav();
		string name();

		string[] support(URL url, string username);
	}
}

interface IDavPluginHub {
	void registerPlugin(IDavPlugin plugin);
	bool hasPlugin(string name);
}


abstract class BaseDavPlugin : IDavPlugin {
	protected IDav _dav;

	this(IDav dav) {
		dav.registerPlugin(this);
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

	void bindResourcePlugins(DavResource resource) { }

	bool hasReport(URL url, string username, string name) {
		return false;
	}

	void report(DavRequest request, DavResponse response) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get report.");
	}

	void notice(string action, DavResource resource) {

	}

	@property {
		IDav dav() {
			return _dav;
		}

		string[] support(URL url, string username) {
			return [];
		}
	}
}

interface IDav : IDavResourceAccess, IDavPluginHub {
	void options(DavRequest request, DavResponse response);
	void propfind(DavRequest request, DavResponse response);
	void lock(DavRequest request, DavResponse response);
	void get(DavRequest request, DavResponse response);
	void put(DavRequest request, DavResponse response);
	void proppatch(DavRequest request, DavResponse response);
	void mkcol(DavRequest request, DavResponse response) ;
	void remove(DavRequest request, DavResponse response);
	void move(DavRequest request, DavResponse response);
	void copy(DavRequest request, DavResponse response);
	void report(DavRequest request, DavResponse response);

	void notice(string action, DavResource resource);

	DavResource[] getResources(URL url, ulong depth, string username);

	@property
	Path rootUrl();
}

/// The main DAV protocol implementation
class Dav : IDav {
	protected {
		Path _rootUrl;

		IDavPlugin[] plugins;
	}

	@property
	Path rootUrl() {
		return _rootUrl;
	}

	this(string rootUrl) {
		_rootUrl = rootUrl;
		_rootUrl.endsWithSlash = true;
		DavStorage.locks = new DavLockList;
	}

	protected {
		DavResource getOrCreateResource(URL url, string username, out int status) {
			DavResource resource;

			if(exists(url, username)) {
				resource = getResource(url, username);
				status = HTTPStatus.ok;
			} else {

				if(!exists(url.parentURL, username))
					throw new DavException(HTTPStatus.conflict, "A resource cannot be created at the destination until one or more intermediate collections have been created.");

				resource = createResource(url, username);
				status = HTTPStatus.created;
			}

			return resource;
		}

		Path checkPath(Path path) {
			path.endsWithSlash = true;
			return path;
		}
	}

	private {

		bool[string] defaultPropList() {
			bool[string] list;

			list["creationdate:DAV:"] = true;
			list["displayname:DAV:"] = true;
			list["getcontentlength:DAV:"] = true;
			list["getcontenttype:DAV:"] = true;
			list["getetag:DAV:"] = true;
			list["lastmodified:DAV:"] = true;
			list["resourcetype:DAV:"] = true;

			return list;
		}

		bool[string] propList(DavProp document) {
			bool[string] list;

			if(document is null || "allprop" in document["propfind"])
				return defaultPropList;

			auto properties = document["propfind"]["prop"];

			if(properties.length > 0)
				foreach(string key, p; properties)
					list[p.tagName ~ ":" ~ p.namespace] = true;

			return list;
		}
	}

	void registerPlugin(IDavPlugin plugin) {
		plugins ~= plugin;
	}

	bool hasPlugin(string name) {

		foreach_reverse(plugin; plugins)
			if(plugin.name == name)
				return true;

		return false;
	}

	void removeResource(URL url, string username) {
		foreach_reverse(plugin; plugins)
			if(plugin.exists(url, username)) {
				notice("deleted", getResource(url, username));
				return plugin.removeResource(url, username);
			}

		throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");
	}

	DavResource getResource(URL url, string username) {
		foreach_reverse(plugin; plugins) {
			if(plugin.exists(url, username)) {
				auto res = plugin.getResource(url, username);
				bindResourcePlugins(res);

				return res;
			}
		}

		throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");
	}

	DavResource[] getResources(URL url, ulong depth, string username) {
		DavResource[] list;
		DavResource[] tmpList;

		tmpList ~= getResource(url, username);

		while(tmpList.length > 0 && depth > 0) {
			auto oldLen = tmpList.length;

			foreach(resource; tmpList) {
				bool[string] childList = resource.getChildren();

				foreach(string key, bool val; childList) {
					tmpList ~= getResource(URL("http://a/" ~ key), username);
				}
			}

			list ~= tmpList[0..oldLen];
			tmpList = tmpList[oldLen..$];
			depth--;
		}

		list ~= tmpList;

		return list;
	}

	DavResource createCollection(URL url, string username) {
		foreach_reverse(plugin; plugins)
			if(plugin.canCreateCollection(url, username)) {
				auto res = plugin.createCollection(url, username);
				bindResourcePlugins(res);

				notice("created", res);

				return res;
			}

		throw new DavException(HTTPStatus.methodNotAllowed, "No plugin available.");
	}

	DavResource createResource(URL url, string username) {
		foreach_reverse(plugin; plugins)
			if(plugin.canCreateResource(url, username)) {
				auto res = plugin.createResource(url, username);
				bindResourcePlugins(res);

				notice("created", res);

				return res;
			}

		throw new DavException(HTTPStatus.methodNotAllowed, "No plugin available.");
	}

	void bindResourcePlugins(DavResource resource) {
		foreach(plugin; plugins)
			plugin.bindResourcePlugins(resource);
	}

	bool exists(URL url, string username) {
		foreach_reverse(plugin; plugins)
			if(plugin.exists(url, username))
				return true;

		return false;
	}

	bool canCreateCollection(URL url, string username) {
		foreach_reverse(plugin; plugins)
			if(plugin.canCreateCollection(url, username))
				return true;

		return false;
	}

	bool canCreateResource(URL url, string username) {
		foreach_reverse(plugin; plugins)
			if(plugin.canCreateResource(url, username))
				return true;

		return false;
	}

	void options(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url, request.username);

		string path = request.path;

		string[] support;

		foreach_reverse(plugin; plugins)
			support ~= plugin.support(request.url, request.username);

		auto allow = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, LOCK, UNLOCK, REPORT";

		response["Accept-Ranges"] = "bytes";
		response["DAV"] = uniq(support).join(",");
		response["Allow"] = allow;
		response["MS-Author-Via"] = "DAV";

		response.flush;
	}

	void propfind(DavRequest request, DavResponse response) {
		bool[string] requestedProperties = propList(request.content);
		DavResource[] list;

		if(!exists(request.url, request.username))
			throw new DavException(HTTPStatus.notFound, "Resource does not exist.");

		list = getResources(request.url, request.depth, request.username);

		response.setPropContent(list, requestedProperties);

		response.flush;
	}

	void proppatch(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		response.statusCode = HTTPStatus.ok;

		DavStorage.locks.check(request.url, ifHeader);
		DavResource resource = getResource(request.url, request.username);

		notice("changed", resource);

		auto xmlString = resource.propPatch(request.content);

		response.content = xmlString;
		response.flush;
	}

	void report(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;

		string report = "";

		foreach_reverse(plugin; plugins) {
			if(plugin.hasReport(request.url, request.username, request.content.reportName)) {
				plugin.report(request, response);
				return;
			}
		}

		throw new DavException(HTTPStatus.notFound, "There is no report.");
	}

	void lock(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;

		DavLockInfo currentLock;

		auto resource = getOrCreateResource(request.url, request.username, response.statusCode);

		if(request.contentLength != 0) {
			currentLock = DavLockInfo.fromXML(request.content, resource);

			if(currentLock.scopeLock == DavLockInfo.Scope.sharedLock && DavStorage.locks.hasExclusiveLock(resource.fullURL))
				throw new DavException(HTTPStatus.locked, "Already has an exclusive locked.");
			else if(currentLock.scopeLock == DavLockInfo.Scope.exclusiveLock && DavStorage.locks.hasLock(resource.fullURL))
				throw new DavException(HTTPStatus.locked, "Already locked.");
			else if(currentLock.scopeLock == DavLockInfo.Scope.exclusiveLock)
				DavStorage.locks.check(request.url, ifHeader);

			DavStorage.locks.add(currentLock);
		} else if(request.contentLength == 0) {
			string uuid = ifHeader.getAttr("", resource.href);

			auto tmpUrl = resource.url;
			while(currentLock is null) {
				currentLock = DavStorage.locks[tmpUrl.toString, uuid];
				tmpUrl = tmpUrl.parentURL;
			}
		} else if(ifHeader.isEmpty)
			throw new DavException(HTTPStatus.internalServerError, "LOCK body expected.");

		if(currentLock is null)
			throw new DavException(HTTPStatus.internalServerError, "LOCK not created.");

		currentLock.timeout = request.timeout;

		response["Lock-Token"] = "<" ~ currentLock.uuid ~ ">";
		response.mimeType = "application/xml";
		response.content = `<?xml version="1.0" encoding="utf-8" ?><d:prop xmlns:d="DAV:"><d:lockdiscovery> ` ~ currentLock.toString ~ `</d:lockdiscovery></d:prop>`;
		response.flush;
	}

	void unlock(DavRequest request, DavResponse response) {
		auto resource = getResource(request.url, request.username);

		DavStorage.locks.remove(resource, request.lockToken);

		response.statusCode = HTTPStatus.noContent;
		response.flush;
	}

	void get(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url, request.username);

		response["Etag"] = "\"" ~ resource.eTag ~ "\"";
		response["Last-Modified"] = toRFC822DateTimeString(resource.lastModified);
		response["Content-Type"] = resource.contentType;
		response["Content-Length"] = resource.contentLength.to!string;

		if(!request.ifModifiedSince(resource) || !request.ifNoneMatch(resource)) {
			response.statusCode = HTTPStatus.NotModified;
			response.flush;
			return;
		}

		response.flush(resource);
		DavStorage.locks.setETag(resource.url, resource.eTag);
	}

	void head(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url, request.username);

		response["Etag"] = "\"" ~ resource.eTag ~ "\"";
		response["Last-Modified"] = toRFC822DateTimeString(resource.lastModified);
		response["Content-Type"] = resource.contentType;
		response["Content-Length"] = resource.contentLength.to!string;

		if(!request.ifModifiedSince(resource) || !request.ifNoneMatch(resource)) {
			response.statusCode = HTTPStatus.NotModified;
			response.flush;
			return;
		}

		response.flush;
		DavStorage.locks.setETag(resource.url, resource.eTag);
	}

	void put(DavRequest request, DavResponse response) {
		DavResource resource = getOrCreateResource(request.url, request.username, response.statusCode);
		DavStorage.locks.check(request.url, request.ifCondition);

		resource.setContent(request.stream, request.contentLength);
		notice("changed", resource);

		DavStorage.locks.setETag(resource.url, resource.eTag);

		response.statusCode = HTTPStatus.created;

		response.flush;
	}

	void mkcol(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;

		if(request.contentLength > 0)
			throw new DavException(HTTPStatus.unsupportedMediaType, "Body must be empty");

		if(!exists(request.url.parentURL, request.username))
			throw new DavException(HTTPStatus.conflict, "Missing parent");

		DavStorage.locks.check(request.url, ifHeader);

		response.statusCode = HTTPStatus.created;
		createCollection(request.url, request.username);
		notice("created", getResource(request.url, request.username));
		response.flush;
	}

	void remove(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		auto url = request.url;

		response.statusCode = HTTPStatus.noContent;

		if(url.anchor != "" || request.requestUrl.indexOf("#") != -1)
			throw new DavException(HTTPStatus.conflict, "Missing parent");

		if(!exists(url, request.username))
			throw new DavException(HTTPStatus.notFound, "Not found.");

		DavStorage.locks.check(url, ifHeader);

		removeResource(url, request.username);

		response.flush;
	}

	void move(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		auto resource = getResource(request.url, request.username);

		DavStorage.locks.check(request.url, ifHeader);
		DavStorage.locks.check(request.destination, ifHeader);

		copy(request, response);
		remove(request, response);

		response.flush;
	}

	void copy(DavRequest request, DavResponse response) {
		string username = request.username;

		URL getDestinationUrl(DavResource source) {
			auto sourceUrl = source.url;
			sourceUrl.host = request.url.host;
			sourceUrl.schema = request.url.schema;
			sourceUrl.port = request.url.port;

			string strSrcUrl = request.url.toString;
			string strDestUrl = request.destination.toString;

			return URL(strDestUrl ~ sourceUrl.toString[strSrcUrl.length..$]);
		}

		void localCopy(DavResource source, DavResource destination) {
			if(source.isCollection) {
				auto list = getResources(request.url, DavDepth.infinity, username);

				foreach(child; list) {
					auto destinationUrl = getDestinationUrl(child);

					if(child.isCollection && !exists(destinationUrl, username))
						createCollection(getDestinationUrl(child), username);
					else if(!child.isCollection) {
						HTTPStatus statusCode;
						DavResource destinationChild = getOrCreateResource(getDestinationUrl(child), username, statusCode);
						destinationChild.setContent(child.stream, child.contentLength);
					}
				}
			} else {
				destination.setContent(source.stream, source.contentLength);
			}

			source.copyPropertiesTo(destination.url);
		}

		DavResource source = getResource(request.url, username);
		DavResource destination;
		HTTPStatus destinationStatus;

		DavStorage.locks.check(request.destination, request.ifCondition);

		if(!exists(request.destination.parentURL, username))
			throw new DavException(HTTPStatus.conflict, "Conflict. `" ~ request.destination.parentURL.toString ~ "` does not exist.");

		if(!request.overwrite && exists(request.destination, username))
			throw new DavException(HTTPStatus.preconditionFailed, "Destination already exists.");

		response.statusCode = HTTPStatus.created;
		if(exists(request.destination, username))
			destination = getResource(request.destination, username);

		response.statusCode = HTTPStatus.created;

		URL destinationUrl = request.destination;

		if(destination !is null && destination.isCollection && !source.isCollection) {
			destinationUrl.path = destinationUrl.path ~ source.url.path.head;
			destination = null;
			response.statusCode = HTTPStatus.noContent;
		}

		if(destination is null) {
			if(source.isCollection)
				destination = createCollection(destinationUrl, username);
			else
				destination = createResource(destinationUrl, username);
		}

		localCopy(source, destination);
		notice("changed", destination);

		response.flush;
	}

	void notice(string action, DavResource resource) {
		foreach_reverse(plugin; plugins)
			plugin.notice(action, resource);
	}
}

/// Hook vibe.d requests to the right DAV method
HTTPServerRequestDelegate serveDav(T : IDav)(T dav) {
	void callback(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {
			debug {
				writeln("\n\n\n");

				writeln("==========================================================");
				writeln(req.fullURL);
				writeln("Method: ", req.method, "\n");

				foreach(key, val; req.headers)
					writeln(key, ": ", val);
			}

			DavRequest request = DavRequest(req);
			DavResponse response = DavResponse(res);

			if(req.method == HTTPMethod.OPTIONS) {
				dav.options(request, response);
			} else if(req.method == HTTPMethod.PROPFIND) {
				dav.propfind(request, response);
			} else if(req.method == HTTPMethod.HEAD) {
				dav.head(request, response);
			} else if(req.method == HTTPMethod.GET) {
				dav.get(request, response);
			} else if(req.method == HTTPMethod.PUT) {
				dav.put(request, response);
			} else if(req.method == HTTPMethod.PROPPATCH) {
				dav.proppatch(request, response);
			} else if(req.method == HTTPMethod.LOCK) {
				dav.lock(request, response);
			} else if(req.method == HTTPMethod.UNLOCK) {
				dav.unlock(request, response);
			} else if(req.method == HTTPMethod.MKCOL) {
				dav.mkcol(request, response);
			} else if(req.method == HTTPMethod.DELETE) {
				dav.remove(request, response);
			} else if(req.method == HTTPMethod.COPY) {
				dav.copy(request, response);
			} else if(req.method == HTTPMethod.MOVE) {
				dav.move(request, response);
			} else if(req.method == HTTPMethod.REPORT) {
				dav.report(request, response);
			} else {
				res.statusCode = HTTPStatus.notImplemented;
				res.writeBody("", "text/plain");
			}
		} catch(DavException e) {
			writeln("ERROR:",e.status.to!int, "(", e.status, ") - ", e.msg);

			res.statusCode = e.status;
			res.writeBody(e.msg, e.mime);
		}

		debug {
			writeln("\nSENT:", res.statusCode.to!int, "(", res.statusCode, ")");
		}
	}

	return &callback;
}
