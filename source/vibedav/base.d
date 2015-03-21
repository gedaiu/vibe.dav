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

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;

import std.conv : to;
import std.algorithm;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.string;
import std.stdio : writeln; //todo: remove this
import std.typecons;
import std.uri;
import tested;

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

enum DavDepth : int {
	zero = 0,
	one = 1,
	infinity = 99
};

/// Represents a general DAV resource
class DavResource {
	string href; //TODO: Where I set this?
	string username;
	URL url;

	protected {
		Dav dav;
		DavProp properties; //TODO: Maybe I should move this to Dav class, or other storage
	}

	this(Dav dav, URL url) {
		this.dav = dav;
		this.url = url;

		string strUrl = url.toString;

		if(strUrl !in dav.resourcePropStorage) {
			dav.resourcePropStorage[strUrl] = new DavProp;
			dav.resourcePropStorage[strUrl].addNamespace("d", "DAV:");
			dav.resourcePropStorage[strUrl]["d:resourcetype"] = "";
		}

		this.properties = dav.resourcePropStorage[strUrl];
	}

	@property {
		string name() {
			return href.baseName;
		}

		string fullURL() {
			return url.toString;
		}

		void isCollection(bool value) {
			if(value)
				properties["d:resourcetype"]["d:collection"] = "";
			else
				properties["d:resourcetype"].remove("d:collection");
		}

		bool isCollection() {
			if("d:collection" in properties["d:resourcetype"])
				return true;
			else
				return false;
		}
	}

	DavProp property(string key) {

		writeln("2. key:", key);

		switch (key) {

			default:
				return properties[key];

			// RFC4918
		    case "getcontentlength:DAV:":
		    	return new DavProp("DAV:", "getcontentlength", contentLength.to!string);

		    case "getetag:DAV:":
		    	return new DavProp("DAV:", "getetag", `"` ~ eTag ~ `"`);

		    case "getlastmodified:DAV:":
		  		return new DavProp("DAV:", "getlastmodified", toRFC822DateTimeString(lastModified));

		    case "lockdiscovery:DAV:":
		    	string strLocks;
		    	bool[string] headerLocks;

		    	if(dav.locks.lockedParentResource(url).length > 0) {
		    		auto list = dav.locks[fullURL];
		    		foreach(lock; list)
		    			strLocks ~= lock.toString;
		    	}

		    	return new DavProp("DAV:", "lockdiscovery", strLocks);

		    case "supportedlock:DAV:":
		    	return new DavProp("<d:supportedlock xmlns:d=\"DAV:\">
							            <d:lockentry>
							              <d:lockscope><d:exclusive/></d:lockscope>
							              <d:locktype><d:write/></d:locktype>
							            </d:lockentry>
							            <d:lockentry>
							              <d:lockscope><d:shared/></d:lockscope>
							              <d:locktype><d:write/></d:locktype>
							            </d:lockentry>
							          </d:supportedlock>");

	case "displayname:DAV:":
		writeln("displayname:", name,":");
		return new DavProp("DAV:", "displayname", name);


/*<A:principal-collection-set/>
<A:principal-URL/>
<A:resource-id/>
<A:current-user-principal/>
<A:supported-report-set/>*/

    	}
	}

	void filterProps(DavProp parent, bool[string] props = cast(bool[string])[]) {
		DavProp item = new DavProp;
		item.parent = parent;
		item.name = "d:response";

		DavProp[][int] result;

		item[`d:href`] = url.path.toNativeString;

		foreach(key; props.keys) {
			DavProp p;
			auto splitPos = key.indexOf(":");
			auto tagName = key[0..splitPos];
			auto tagNameSpace = key[splitPos+1..$];

			try {
				p = property(key);
				result[200] ~= p;
			} catch (DavException e) {
				p = new DavProp;
				p.name = tagName;
				p.namespaceAttr = tagNameSpace;
				result[e.status] ~= p;
			}
		}

		/// Add the properties by status
		foreach(code; result.keys) {
			auto propStat = new DavProp;
			propStat.parent = item;
			propStat.name = "d:propstat";
			propStat["d:prop"] = "";

			foreach(p; result[code]) {
				propStat["d:prop"].addChild(p);
			}

			propStat["d:status"] = `HTTP/1.1 ` ~ code.to!string ~ ` ` ~ httpStatusText(code);
			item.addChild(propStat);
		}

		item["d:status"] = `HTTP/1.1 200 OK`;

		parent.addChild(item);
	}

	bool hasChild(Path path) {
		auto childList = getChildren;

		foreach(c; childList)
			if(c.href == path.to!string)
				return true;

		return false;
	}

	string propPatch(DavProp document) {
		string description;
		string result = `<?xml version="1.0" encoding="utf-8" ?><d:multistatus xmlns:d="DAV:"><d:response>`;
		result ~= `<d:href>` ~ url.toString ~ `</d:href>`;

		//remove properties
		auto updateList = [document].getTagChilds("propertyupdate");

		foreach(string key, item; updateList[0]) {
			if(item.tagName == "remove") {
				auto removeList = [item].getTagChilds("prop");

				foreach(prop; removeList)
					foreach(string key, p; prop) {
						properties.remove(key);
						result ~= `<d:propstat><d:prop>` ~ p.toString ~ `</d:prop>`;
						HTTPStatus status = HTTPStatus.notFound;
						result ~= `<d:status>HTTP/1.1 ` ~ status.to!int.to!string ~ ` ` ~ status.to!string ~ `</d:status></d:propstat>`;
					}
			}
			else if(item.tagName == "set") {
				auto setList = [item].getTagChilds("prop");

				foreach(prop; setList) {
					foreach(string key, p; prop) {
						properties[key] = p;
						result ~= `<d:propstat><d:prop>` ~ p.toString ~ `</d:prop>`;
						HTTPStatus status = HTTPStatus.ok;
						result ~= `<d:status>HTTP/1.1 ` ~ status.to!int.to!string ~ ` ` ~ status.to!string ~ `</d:status></d:propstat>`;
					}
				}
			}
		}

		if(description != "")
			result ~= `<d:responsedescription>` ~ description ~ `</d:responsedescription>`;

		result ~= `</d:response></d:multistatus>`;

		string strUrl = url.toString;
		dav.resourcePropStorage[strUrl] = properties;

		return result;
	}

	void setProp(string name, DavProp prop) {
		properties[name] = prop;
		dav.resourcePropStorage[url.toString][name] = prop;
	}

	void removeProp(string name) {
		string urlStr = url.toString;

		if(name in properties) properties.remove(name);
		if(name in dav.resourcePropStorage[urlStr]) dav.resourcePropStorage[urlStr].remove(name);
	}

	void remove() {
		string strUrl = url.toString;

		if(strUrl in dav.resourcePropStorage)
			dav.resourcePropStorage.remove(strUrl);
	}

	HTTPStatus copy(URL destinationURL, bool overwrite = false) {
		dav.resourcePropStorage[destinationURL.toString] = dav.resourcePropStorage[url.toString];

		return HTTPStatus.ok;
	}

	abstract {
		DavResource[] getChildren(ulong depth = 1);
		HTTPStatus move(URL newPath, bool overwrite = false);
		void setContent(const ubyte[] content);
		void setContent(InputStream content, ulong size);

		@property {
			string eTag();
			string mimeType();
			SysTime lastModified();
			ulong contentLength();
			InputStream stream();
		}
	}
}

interface IDav {
	abstract {
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
	}
}

abstract class DavBase : IDav {
	protected Path rootUrl;

	DavProp[string] resourcePropStorage;
	DavLockList locks;

	abstract DavResource getResource(URL url);
	abstract DavResource createCollection(URL url);
	abstract DavResource createProperty(URL url);

	this(string rootUrl) {
		this.rootUrl = checkPath(Path(rootUrl));
	}

	protected {
		DavResource getOrCreateResource(URL url, out int status) {
			DavResource resource;

			try {
				resource = getResource(url);
				status = HTTPStatus.ok;
			} catch (DavException e) {
				if(e.status != HTTPStatus.notFound)
					throw e;

				resource = createProperty(url);
				status = HTTPStatus.created;
			}

			return resource;
		}

		Path checkPath(Path path) {
			if(!path.endsWithSlash) {
				return Path(path.toNativeString ~ "/");
			}

			return path;
		}
	}
}


/// The main DAV protocol implementation
abstract class Dav : DavBase {

	this(string rootUrl) {
		super(rootUrl);
		locks = new DavLockList;
	}

	private {
		bool[string] propList(DavProp document) {
			bool[string] list;

			auto properties = document["propfind"]["prop"];

			if(properties.length > 0)
				foreach(string key, p; properties) {
					list[p.tagName ~ ":" ~ p.namespace] = true;
				}

			return list;
		}
	}

	void options(DavRequest request, DavResponse response) {
		string path = request.path;

		response["Accept-Ranges"] = "bytes";
		response["DAV"] = "1,2,3";
		response["Allow"] = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, LOCK, UNLOCK";
		response["MS-Author-Via"] = "DAV";

		response.flush;
	}

	void propfind(DavRequest request, DavResponse response) {
		bool[string] requestedProperties = propList(request.content);

		auto selectedResource = getResource(request.url);
		selectedResource.username = request.username;
		writeln("request.username ", request.username);

		auto pfResponse = new PropfindResponse();
		pfResponse.list ~= selectedResource;

		if(selectedResource.isCollection)
			pfResponse.list ~= selectedResource.getChildren(request.depth);

		response.statusCode = HTTPStatus.multiStatus;
		response.mimeType = "application/xml";

		if(requestedProperties.length == 0)
			response.content = pfResponse.toString;
		else
			response.content = pfResponse.toStringProps(requestedProperties);

		response.flush;
	}


	void lock(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;

		DavLockInfo currentLock;

		auto resource = getOrCreateResource(request.url, response.statusCode);

		if(request.contentLength != 0) {
			currentLock = DavLockInfo.fromXML(request.content, resource);

			if(currentLock.scopeLock == DavLockInfo.Scope.sharedLock && locks.hasExclusiveLock(resource.fullURL))
				throw new DavException(HTTPStatus.locked, "Already has an exclusive locked.");
			else if(currentLock.scopeLock == DavLockInfo.Scope.exclusiveLock && locks.hasLock(resource.fullURL))
				throw new DavException(HTTPStatus.locked, "Already locked.");
			else if(currentLock.scopeLock == DavLockInfo.Scope.exclusiveLock)
				locks.check(request.url, ifHeader);

			locks.add(currentLock);
		} else if(request.contentLength == 0) {
			string uuid = ifHeader.getAttr("", resource.href);

			auto tmpUrl = resource.url;
			while(currentLock is null) {
				currentLock = locks[tmpUrl.toString, uuid];
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

		locks.remove(resource, request.lockToken);

		response.statusCode = HTTPStatus.noContent;
		response.flush;
	}

	void get(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url);

		response["Etag"] = "\"" ~ resource.eTag ~ "\"";
		response["Last-Modified"] = toRFC822DateTimeString(resource.lastModified);
		response["Content-Type"] = resource.mimeType;
		response["Content-Length"] = resource.contentLength.to!string;

		if(!request.ifModifiedSince(resource) || !request.ifNoneMatch(resource)) {
			response.statusCode = HTTPStatus.NotModified;
			response.flush;
			return;
		}

		response.flush(resource);
		locks.setETag(resource.url, resource.eTag);
	}

	void head(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url);

		response["Etag"] = "\"" ~ resource.eTag ~ "\"";
		response["Last-Modified"] = toRFC822DateTimeString(resource.lastModified);
		response["Content-Type"] = resource.mimeType;
		response["Content-Length"] = resource.contentLength.to!string;

		if(!request.ifModifiedSince(resource) || !request.ifNoneMatch(resource)) {
			response.statusCode = HTTPStatus.NotModified;
			response.flush;
			return;
		}

		response.flush;
		locks.setETag(resource.url, resource.eTag);
	}

	void put(DavRequest request, DavResponse response) {
		DavResource resource = getOrCreateResource(request.url, response.statusCode);

		locks.check(request.url, request.ifCondition);

		resource.setContent(request.stream, request.contentLength);

		locks.setETag(resource.url, resource.eTag);

		response.statusCode = HTTPStatus.created;
		response.flush;
	}

	void proppatch(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		response.statusCode = HTTPStatus.ok;

		locks.check(request.url, ifHeader);

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

		locks.check(request.url, ifHeader);

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
		locks.check(url, ifHeader);

		resource.remove();
		response.flush;
	}

	void move(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		auto resource = getResource(request.url);

		locks.check(request.url, ifHeader);
		locks.check(request.destination, ifHeader);

		response.statusCode = resource.move(request.destination, request.overwrite);
		response.flush;
	}

	void copy(DavRequest request, DavResponse response) {
		auto resource = getResource(request.url);

		locks.check(request.destination, request.ifCondition);

		response.statusCode = resource.copy(request.destination, request.overwrite);
		response.flush;
	}
}

HTTPServerRequestDelegate serveDav(T : Dav)(T dav) {
	void callback(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {

			debug {
				writeln("\n\n\n");

				writeln("==========================================================");
				writeln(req.fullURL);
				writeln("Method: ", req.method);

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
			writeln("SUCCESS:", res.statusCode.to!int, "(", res.statusCode, ")");
		}
	}

	return &callback;
}
