/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 15, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.base;

public import vibedav.prop;
public import vibedav.ifheader;
public import vibedav.locks;
public import vibedav.http;
public import vibedav.user;
public import vibedav.davresource;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.internal.meta.uda;

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
		DavProp[string] resourcePropStorage;
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

interface IDav {
	DavResource getResource(URL url);
	DavResource createCollection(URL url);
	DavResource createProperty(URL url);

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

	@property
	Path rootUrl();
}

abstract class DavBase : IDav {
	protected Path _rootUrl;

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
		DavResource getOrCreateResource(URL url, out int status) {
			DavResource resource;

			if(exists(url)) {
				resource = getResource(url);
				status = HTTPStatus.ok;
			} else {
				resource = createProperty(url);
				status = HTTPStatus.created;
			}

			return resource;
		}

		bool exists(URL url) {
			try {
				getResource(url);
			} catch (DavException e) {
				if(e.status != HTTPStatus.notFound)
					throw e;

				return false;
			}

			return true;
		}

		Path checkPath(Path path) {
			path.endsWithSlash = true;
			return path;
		}
	}
}

/// The main DAV protocol implementation
abstract class Dav : DavBase {
	IDavUserCollection userCollection;

	this(string rootUrl) {
		super(rootUrl);
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

	void options(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url);

		string path = request.path;

		auto support = (["1", "2", "3"] ~ resource.extraSupport).join(",");

		response["Accept-Ranges"] = "bytes";
		response["DAV"] = support;
		response["Allow"] = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, LOCK, UNLOCK";
		response["MS-Author-Via"] = "DAV";

		response.flush;
	}

	void propfind(DavRequest request, DavResponse response) {
		bool[string] requestedProperties = propList(request.content);
		DavResource[] list;

		auto selectedResource = getResource(request.url);
		selectedResource.user = userCollection.GetDavUser(request.username);

		list ~= selectedResource;
		if(selectedResource.isCollection)
			list ~= selectedResource.getChildren(request.depth);

		response.setPropContent(list, requestedProperties);
		response.flush;
	}

	void lock(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;

		DavLockInfo currentLock;

		auto resource = getOrCreateResource(request.url, response.statusCode);

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
		auto resource = getResource(request.url);

		DavStorage.locks.remove(resource, request.lockToken);

		response.statusCode = HTTPStatus.noContent;
		response.flush;
	}

	void get(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url);

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
		DavResource resource = getResource(request.url);

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
		DavResource resource = getOrCreateResource(request.url, response.statusCode);

		DavStorage.locks.check(request.url, request.ifCondition);

		resource.setContent(request.stream, request.contentLength);

		DavStorage.locks.setETag(resource.url, resource.eTag);

		response.statusCode = HTTPStatus.created;
		response.flush;
	}

	void proppatch(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		response.statusCode = HTTPStatus.ok;

		DavStorage.locks.check(request.url, ifHeader);
		DavResource resource = getResource(request.url);

		auto xmlString = resource.propPatch(request.content);

		response.content = xmlString;
		response.flush;
	}

	void mkcol(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;

		if(request.contentLength > 0)
			throw new DavException(HTTPStatus.unsupportedMediaType, "Body must be empty");

		try auto resource = getResource(request.url.parentURL);

		catch (DavException e)
			if(e.status == HTTPStatus.notFound)
				throw new DavException(HTTPStatus.conflict, "Missing parent");

		DavStorage.locks.check(request.url, ifHeader);

		response.statusCode = HTTPStatus.created;
		createCollection(request.url);
		response.flush;
	}

	void remove(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		auto url = request.url;

		response.statusCode = HTTPStatus.noContent;

		if(url.anchor != "" || request.requestUrl.indexOf("#") != -1)
			throw new DavException(HTTPStatus.conflict, "Missing parent");

		auto resource = getResource(url);
		DavStorage.locks.check(url, ifHeader);

		resource.remove();
		response.flush;
	}

	void move(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		auto resource = getResource(request.url);

		DavStorage.locks.check(request.url, ifHeader);
		DavStorage.locks.check(request.destination, ifHeader);

		copy(request, response);
		remove(request, response);

		response.flush;
	}

	void copy(DavRequest request, DavResponse response) {

		URL getDestinationUrl(DavResource source) {
			string strSrcUrl = request.url.toString;
			string strDestUrl = request.destination.toString;

			return URL(strDestUrl ~ source.url.toString[strSrcUrl.length..$]);
		}

		void localCopy(DavResource source, DavResource destination) {
			source.copy(destination.url);

			if(source.isCollection) {
				auto list = source.getChildren(DavDepth.infinity);

				foreach(child; list) {
					auto destinationUrl = getDestinationUrl(child);

					if(child.isCollection && !exists(destinationUrl)) {
						auto destinationChild = createCollection(getDestinationUrl(child));
						child.copy(destinationChild.url, request.overwrite);
					} else if(!child.isCollection) {
						HTTPStatus statusCode;
						DavResource destinationChild = getOrCreateResource(getDestinationUrl(child), statusCode);
						destinationChild.setContent(child.stream, child.contentLength);
						child.copy(destinationChild.url, request.overwrite);
					}
				}
			} else {
				destination.setContent(source.stream, source.contentLength);
			}
		}

		DavResource source = getResource(request.url);
		DavResource destination;
		HTTPStatus destinationStatus;

		DavStorage.locks.check(request.destination, request.ifCondition);

		if(!exists(request.destination.parentURL))
			throw new DavException(HTTPStatus.conflict, "Conflict. `" ~ request.destination.parentURL.toString ~ "` does not exist.");

		if(!request.overwrite && exists(request.destination))
			throw new DavException(HTTPStatus.preconditionFailed, "Destination already exists.");

		response.statusCode = HTTPStatus.created;
		if(exists(request.destination)) {
			destination = getResource(request.destination);
		}

		response.statusCode = HTTPStatus.created;

		URL destinationUrl = request.destination;

		if(destination !is null && destination.isCollection && !source.isCollection) {
			destinationUrl.path = destinationUrl.path ~ source.url.path.head;
			destination = null;
			response.statusCode = HTTPStatus.noContent;
		}

		if(destination is null) {
			if(source.isCollection)
				destination = createCollection(destinationUrl);
			else
				destination = createProperty(destinationUrl);
		}

		localCopy(source, destination);

		response.flush;
	}
}


/// Hook vibe.d requests to the right DAV method
HTTPServerRequestDelegate serveDav(T : Dav)(T dav) {
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
			writeln("\nSUCCESS:", res.statusCode.to!int, "(", res.statusCode, ")");
		}
	}

	return &callback;
}
