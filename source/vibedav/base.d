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
import std.stdio; //todo: remove this
import std.typecons;
import std.uri;
import tested;


struct ResourceProperty {
	string name;
	string ns;
}

ResourceProperty getResourceProperty(T...)() {
	static if(T.length == 0)
		static assert(false, "There is no `@ResourceProperty` attribute.");
	else static if( is(typeof(T[0]) == ResourceProperty) )
		return T[0];
	else
		return getResourceProperty(T[1..$]);
}


pure bool hasDavInterfaceProperties(I)(string key) {
	bool result = false;

	void keyExist(T...)() {
		static if(T.length > 0) {
			enum val = getResourceProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum staticKey = val.name ~ ":" ~ val.ns;

			if(staticKey == key)
				result = true;

			keyExist!(T[1..$])();
		}
	}

	keyExist!(__traits(allMembers, I))();

	return result;
}

DavProp propFrom(T)(string name, string ns, T value) {
	string v;

	static if( is(T == string) )
	{
		return new DavProp(name, ns, value);
	}
	else static if( is(T == SysTime) )
	{
		return new DavProp(name, ns, toRFC822DateTimeString(value));
	}
	else
	{
		return new DavProp(name, ns, value.to!string);
	}
}

DavProp getDavInterfaceProperties(I)(string key, I davInterface) {
	DavProp result;

	void getProp(T...)() {
		static if(T.length > 0) {
			enum val = getResourceProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum staticKey = val.name ~ ":" ~ val.ns;

			if(staticKey == key) {
				auto value = __traits(getMember, davInterface, T[0]);
				pragma(msg, "\n", T[0], " ", typeof(value));
				result = propFrom(val.name, val.ns, value);
			}

			getProp!(T[1..$])();
		}
	}

	getProp!(__traits(allMembers, I))();

	return result;
}

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

enum DavDepth : int {
	zero = 0,
	one = 1,
	infinity = 99
};

interface IDavResourceProperties {

	@property {
		@ResourceProperty("creationdate", "DAV:")
		SysTime creationDate();

		@ResourceProperty("lastmodified", "DAV:")
		SysTime lastModified();

		@ResourceProperty("getetag", "DAV:")
		string eTag();

		@ResourceProperty("getcontenttype", "DAV:")
		string contentType();

		@ResourceProperty("getcontentlength", "DAV:")
		ulong contentLength();

		@ResourceProperty("resourcetype", "DAV:")
		bool isCollection();
	}
}

/// Represents a general DAV resource
class DavResource : IDavResourceProperties {
	string href;
	URL url;
	IDavUser user;

	protected {
		IDav dav;
		DavProp properties; //TODO: Maybe I should move this to Dav class, or other storage
	}

	this(IDav dav, URL url) {
		this.dav = dav;
		this.url = url;

		string strUrl = url.toString;

		if(strUrl !in DavStorage.resourcePropStorage) {
			DavStorage.resourcePropStorage[strUrl] = new DavProp;
			DavStorage.resourcePropStorage[strUrl].addNamespace("d", "DAV:");
		}

		this.properties = DavStorage.resourcePropStorage[strUrl];
	}

	@property {
		string name() {
			return href.baseName;
		}

		string fullURL() {
			return url.toString;
		}

		string[] extraSupport() {
			string[] headers;
			return headers;
		}
	}

	DavProp property(string key) {

		if(user !is null && user.hasProperty(key))
			return DavProp.FromKeyAndList(key, user.property(key));

		if(hasDavInterfaceProperties!IDavResourceProperties(key))
			return getDavInterfaceProperties!IDavResourceProperties(key, this);

		switch (key) {

			default:
				return properties[key];

		    case "lockdiscovery:DAV:":
		    	string strLocks;
		    	bool[string] headerLocks;

		    	if(DavStorage.locks.lockedParentResource(url).length > 0) {
		    		auto list = DavStorage.locks[fullURL];
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
				return new DavProp("DAV:", "displayname", name);
    	}
	}

	void filterProps(DavProp parent, bool[string] props) {
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

			foreach(p; result[code])
				propStat["d:prop"].addChild(p);

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
		DavStorage.resourcePropStorage[strUrl] = properties;

		return result;
	}

	void setProp(string name, DavProp prop) {
		properties[name] = prop;
		DavStorage.resourcePropStorage[url.toString][name] = prop;
	}

	void removeProp(string name) {
		string urlStr = url.toString;

		if(name in properties) properties.remove(name);
		if(name in DavStorage.resourcePropStorage[urlStr]) DavStorage.resourcePropStorage[urlStr].remove(name);
	}

	void remove() {
		string strUrl = url.toString;

		if(strUrl in DavStorage.resourcePropStorage)
			DavStorage.resourcePropStorage.remove(strUrl);
	}

	HTTPStatus copy(URL destinationURL, bool overwrite = false) {
		DavStorage.resourcePropStorage[destinationURL.toString] = DavStorage.resourcePropStorage[url.toString];

		return HTTPStatus.ok;
	}

	abstract {
		DavResource[] getChildren(ulong depth = 1);
		void setContent(const ubyte[] content);
		void setContent(InputStream content, ulong size);
		@property InputStream stream();
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
		bool[string] propList(DavProp document) {
			bool[string] list;

			if(document is null)
				return list;

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

		writeln("1. selectedResource ", request.url);
		auto selectedResource = getResource(request.url);
		writeln("2. selectedResource ", selectedResource);
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

/// File dav impplementation
class DavFs(T) : Dav {
	protected {
		Path _rootFile;
	}

	this() {
		this("","");
	}

	this(string rootUrl, string _rootFile) {
		super(rootUrl);
		this._rootFile = Path(_rootFile);
	}

	Path filePath(URL url) {
		return _rootFile ~ url.path.toString[rootUrl.toString.length..$];
	}

	DavResource getResource(URL url) {
		auto filePath = filePath(url);

		if(!filePath.toString.exists)
			throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

		return new T(this, url);
	}

	DavResource createCollection(URL url) {
		auto filePath = filePath(url);

		if(filePath.toString.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "plain/text");

		mkdir(filePath.toString);
		return new T(this, url);
	}

	DavResource createProperty(URL url) {
		auto filePath = filePath(url);
		auto strFilePath = filePath.toString;

		if(strFilePath.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "plain/text");

		if(filePath.endsWithSlash) {
			strFilePath.mkdirRecurse;
		} else {
			auto f = new File(strFilePath, "w");
			f.close;
		}

		return new T(this, url);
	}

	@property
	Path rootFile() {
		return _rootFile;
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

void serveDavFs(T)(URLRouter router, string rootUrl, string rootPath, IDavUserCollection userCollection) {
	auto fileDav = new DavFs!T(rootUrl, rootPath);
	fileDav.userCollection = userCollection;
	router.any(rootUrl ~ "*", serveDav(fileDav));
}
