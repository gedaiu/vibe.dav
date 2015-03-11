/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 15, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.base;

public import vibedav.util;
public import vibedav.prop;
public import vibedav.ifheader;
public import vibedav.locks;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.utils.dictionarylist;

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

alias HeaderList = DictionaryList!(string, false, 32L);

string getHeaderValue(HeaderList headers, string name, string defaultValue = "") {

	string value = defaultValue;

	if(name !in headers && defaultValue == "")
		throw new DavException(HTTPStatus.internalServerError, "Can't find '"~name~"' in headers.");
	else
		value = headers.get(name, defaultValue);

	return value;
}

@name("basic check for getHeaderValue")
unittest {
	HeaderList list;
	list["key"] = "value";
	auto val = getHeaderValue(list, "key");
	assert(val == "value");
}

@name("getHeaderValue with default value")
unittest {
	HeaderList list;
	auto val = getHeaderValue(list, "key", "default");
	assert(val == "default");
}

@name("check if getHeaderValue fails")
unittest {
	bool raised = false;

	try {
		HeaderList list;
		list["key"] = "value";
		getHeaderValue(list, "key1");
	} catch(DavException e) {
		raised = true;
	}

	assert(raised);
}

void enforce(string[] valid)(string value) {

}

string getHeader(string name)(HeaderList headers) {
	string value;

	static if(name == "Depth") {
		value = getHeaderValue(headers, name, "infinity");
		value.enforce!(["0", "1", "infinity"]);
	} else static if(name == "Overwrite") {
		value = getHeaderValue(headers, name, "F");
		value.enforce!(["T", "F"]);
	} else static if(name == "If") {
		value = getHeaderValue(headers, name, "()");
	} else {
		value = getHeaderValue(headers, name);
	}

	return value;
}

IfHeader getIfHeader(HTTPServerRequest req) {
	return IfHeader.parse(getHeader!"If"(req.headers));
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

DavDepth getDepthHeader(HTTPServerRequest req) {
	if("depth" in req.headers) {
		string strDepth = getHeader!"Depth"(req.headers);

		if(strDepth == "0") return DavDepth.zero;
		if(strDepth == "1") return DavDepth.one;
	}

	return DavDepth.infinity;
}


/// Represents a general DAV resource
class DavResource {
	string href; //TODO: Where I set this?
	URL url;

	DavProp properties; //TODO: Maybe I should move this to Dav class, or other storage
	HTTPStatus statusCode;

	protected {
		Dav dav;
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

	void filterProps(DavProp parent, bool[string] props = cast(bool[string])[]) {
		DavProp item = new DavProp;
		item.parent = parent;

		DavProp[][int] result;

		item[`d:href`] = url.to!string;

		foreach(key; props.keys) {
			DavProp p;
			auto splitPos = key.indexOf(":");
			auto tagName = key[0..splitPos];
			auto tagNameSpace = key[splitPos+1..$];

			try {
				p = properties[key];
				result[200] ~= p;
			} catch (DavException e) {
				p = new DavProp;
				p.name = tagName;
				p.namespaceAttr = tagNameSpace;
				result[e.status] ~= p;
			}
		}

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

		item["d:status"] = `HTTP/1.1 ` ~ statusCode.to!int.to!string ~ ` ` ~ httpStatusText(statusCode);

		parent.addChild(item);
	}

	bool hasChild(Path path) {
		auto childList = getChildren;

		foreach(c; childList)
			if(c.href == path.to!string)
				return true;

		return false;
	}

	string propPatch(string content) {
		string description;
		string result = `<?xml version="1.0" encoding="utf-8" ?><d:multistatus xmlns:d="DAV:"><d:response>`;
		result ~= `<d:href>` ~ url.toString ~ `</d:href>`;

		auto document = parseXMLProp(content);


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
						writeln("set", key);
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

	abstract DavResource[] getChildren(ulong depth = 1);
	abstract HTTPStatus move(URL newPath, bool overwrite = false);
	abstract void setContent(const ubyte[] content);
	@property abstract string eTag();
}

/// A structure that helps to create the propfind response
struct PropfindResponse {

	DavResource list[];

	string toString() {
		bool[string] props;
		return toStringProps(props);
	}

	string toStringProps(bool[string] props) {
		string str = `<?xml version="1.0" encoding="UTF-8"?>`;
		auto response = parseXMLProp(`<d:multistatus xmlns:d="DAV:"><d:response></d:response></d:multistatus>`);

		foreach(item; list) {
			item.filterProps(response["d:multistatus"]["d:response"], props);
		}

		return str ~ response.toString;
	}
}

interface IDav {
	abstract {
		DavResource getResource(URL url);
		DavResource createCollection(URL url);
		DavResource createProperty(URL url);

		void options(HTTPServerRequest req, HTTPServerResponse res);
		void propfind(HTTPServerRequest req, HTTPServerResponse res);
		void lock(HTTPServerRequest req, HTTPServerResponse res);
		void get(HTTPServerRequest req, HTTPServerResponse res);
		void put(HTTPServerRequest req, HTTPServerResponse res);
		void proppatch(HTTPServerRequest req, HTTPServerResponse res);
		void mkcol(HTTPServerRequest req, HTTPServerResponse res) ;
		void remove(HTTPServerRequest req, HTTPServerResponse res);
		void move(HTTPServerRequest req, HTTPServerResponse res);
		void copy(HTTPServerRequest req, HTTPServerResponse res);
	}
}

abstract class DavBase : IDav {
	Path root;
	DavProp[string] resourcePropStorage;
	DavLockList locks;

	abstract DavResource getResource(URL url);
	abstract DavResource createCollection(URL url);
	abstract DavResource createProperty(URL url);

	protected {
		DavResource getOrCreateResource(URL url, out int status) {
			DavResource resource;

			try {
				resource = getResource(url);
				status = HTTPStatus.ok;
			} catch (DavException e){
				if(e.status != HTTPStatus.notFound)
					throw e;

				resource = createProperty(url);
				status = HTTPStatus.created;
			}

			return resource;
		}
	}
}


/// The main DAV protocol implementation
abstract class Dav : DavBase {

	this() {
		locks = new DavLockList;
	}

	private {
		bool[string] propList(DavProp document) {
			bool[string] list;

			auto properties = document["propfind"]["prop"];

			if(properties.length > 0)
				foreach(string key, p; properties)
					list[key ~ ":" ~ p.namespace] = true;

			return list;
		}

		string getRequestPath(HTTPServerRequest req) {
			string path = req.path;
			return path;
		}
	}


	void options(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;

		res.headers["Accept-Ranges"] = "bytes";
		res.headers["DAV"] = "1,2,3";
		res.headers["Allow"] = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, LOCK, UNLOCK";
		res.headers["MS-Author-Via"] = "DAV";

		res.writeBody("", "text/plain");
	}

	void propfind(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);
		int depth = getDepthHeader(req).to!int;
		bool[string] requestedProperties;

		string requestXml = cast(string)req.bodyReader.readAllUTF8;

		if(requestXml.length > 0) {
			DavProp document;
			try document = requestXml.parseXMLProp;
			catch (DavPropException e)
				throw new DavException(HTTPStatus.badRequest, "Invalid xml body.");

			requestedProperties = propList(document);
		}

		auto selectedResource = getResource(req.fullURL);

		auto response = new PropfindResponse();
		response.list ~= selectedResource;

		if(selectedResource.isCollection)
			response.list ~= selectedResource.getChildren(depth);

		res.statusCode = HTTPStatus.multiStatus;

		if(requestedProperties.length == 0)
			res.writeBody(response.toString, "application/xml");
		else
			res.writeBody(response.toStringProps(requestedProperties), "application/xml");
	}

	void lock(HTTPServerRequest req, HTTPServerResponse res) {
		auto ifHeader = getIfHeader(req);
		string timeout = getHeader!"Timeout"(req.headers);

		string path = getRequestPath(req);
		ulong depth = getDepthHeader(req);

		DavLockInfo currentLock;

		string requestXml = cast(string)req.bodyReader.readAllUTF8;
		auto resource = getOrCreateResource(req.fullURL, res.statusCode);

		if(requestXml.length != 0) {
			locks.check(req.fullURL, ifHeader);
			currentLock = locks.create(resource, requestXml);
		} else if(requestXml.length == 0) {
			string lockId = ifHeader.getAttr("", resource.href);
			currentLock = locks[resource.fullURL, lockId];
		} else if(ifHeader.isEmpty) {
			throw new DavException(HTTPStatus.internalServerError, "LOCK body expected.");
		}

		if(currentLock is null)
			throw new DavException(HTTPStatus.internalServerError, "LOCK not created.");

		currentLock.setTimeout(timeout);

		res.headers["Lock-Token"] = "<"~currentLock.uuid~">";
		res.writeBody(currentLock.toString, "application/xml");
	}

	void get(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);
		res.statusCode = HTTPStatus.ok;

		DavResource resource = getOrCreateResource(req.fullURL, res.statusCode);

		sendRawFile(req, res, root ~ path[1..$], new HTTPFileServerSettings);

		locks.setETag(resource.url, resource.eTag);
	}

	void head(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);
		DavResource resource = getResource(req.fullURL);

		res.statusCode = HTTPStatus.ok;
		sendRawFile(req, res, root ~ path[1..$], new HTTPFileServerSettings, true);
		writeln("2.|"~res.headers["Etag"][1..$-1]~"|");
		locks.setETag(resource.url, resource.eTag);
	}

	void put(HTTPServerRequest req, HTTPServerResponse res) {
		auto ifHeader = getIfHeader(req);
		string path = getRequestPath(req);

		DavResource resource = getOrCreateResource(req.fullURL, res.statusCode);

		locks.check(req.fullURL, ifHeader);

		auto content = req.bodyReader.readAll;
		resource.setContent(content);

		locks.setETag(resource.url, resource.eTag);

		res.writeBody("", "text/plain");
	}

	void proppatch(HTTPServerRequest req, HTTPServerResponse res) {
		auto ifHeader = getIfHeader(req);
		string path = getRequestPath(req);
		res.statusCode = HTTPStatus.ok;

		DavResource resource = getResource(req.fullURL);
		locks.check(req.fullURL, ifHeader);

		auto content = req.bodyReader.readAllUTF8;
		auto xmlString = resource.propPatch(content);

		res.writeBody(xmlString, "text/plain");
	}

	void mkcol(HTTPServerRequest req, HTTPServerResponse res) {
		auto ifHeader = getIfHeader(req);
		string path = getRequestPath(req);

		auto content = req.bodyReader.readAll;
		if(content.length > 0)
			throw new DavException(HTTPStatus.unsupportedMediaType, "Body must be empty");

		try {
			auto resource = getResource(req.fullURL.parentURL);
		} catch (DavException e) {
			if(e.status == HTTPStatus.notFound)
				throw new DavException(HTTPStatus.conflict, "Missing parent");
		}

		locks.check(req.fullURL, ifHeader);

		res.statusCode = HTTPStatus.created;
		createCollection(req.fullURL);
		res.writeBody("", "text/plain");
	}

	void remove(HTTPServerRequest req, HTTPServerResponse res) {
		auto ifHeader = getIfHeader(req);
		string path = getRequestPath(req);
		auto url = req.fullURL;

		res.statusCode = HTTPStatus.noContent;

		if(url.anchor != "" || req.requestURL.indexOf("#") != -1)
			throw new DavException(HTTPStatus.conflict, "Missing parent");

		auto resource = getResource(url);
		locks.check(req.fullURL, ifHeader);

		resource.remove();
		res.writeBody("", "text/plain");
	}

	void move(HTTPServerRequest req, HTTPServerResponse res) {
		string destination = getHeader!"Destination"(req.headers);
		string overwrite = getHeader!"Overwrite"(req.headers);

		auto ifHeader = getIfHeader(req);
		string path = getRequestPath(req);
		auto destinationURL = URL(destination);

		auto resource = getResource(req.fullURL);

		locks.check(req.fullURL, ifHeader);
		locks.check(destinationURL, ifHeader);

		res.statusCode = resource.move(destinationURL, overwrite == "T");

		res.writeBody("", "text/plain");
	}

	void copy(HTTPServerRequest req, HTTPServerResponse res) {
		auto ifHeader = getIfHeader(req);
		string destination = getHeader!"Destination"(req.headers);
		string overwrite = getHeader!"Overwrite"(req.headers);
		string path = getRequestPath(req);
		auto destinationURL = URL(destination);

		auto resource = getResource(req.fullURL);

		locks.check(destinationURL, ifHeader);

		res.statusCode = resource.copy(destinationURL, overwrite == "T");

		res.writeBody("", "text/plain");
	}
}

HTTPServerRequestDelegate serveDav(T : Dav)(Path path) {
	auto dav = new T;
	dav.root = path;

	void callback(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {

			debug {
				if("X-Litmus" in req.headers) {
					writeln("\n\n\n");
					writeln(req.fullURL);
					writeln(req.headers["X-Litmus"]);
					writeln("Method: ", req.method);
					writeln("==========================");
				}
			}

			if(req.method == HTTPMethod.OPTIONS) {
				dav.options(req, res);
			} else if(req.method == HTTPMethod.PROPFIND) {
				dav.propfind(req, res);
			} else if(req.method == HTTPMethod.HEAD) {
				dav.head(req, res);
			} else if(req.method == HTTPMethod.GET) {
				dav.get(req, res);
			} else if(req.method == HTTPMethod.PUT) {
				dav.put(req, res);
			} else if(req.method == HTTPMethod.PROPPATCH) {
				dav.proppatch(req, res);
			} else if(req.method == HTTPMethod.LOCK) {
				dav.lock(req, res);
			} else if(req.method == HTTPMethod.MKCOL) {
				dav.mkcol(req, res);
			} else if(req.method == HTTPMethod.DELETE) {
				dav.remove(req, res);
			} else if(req.method == HTTPMethod.COPY) {
				dav.copy(req, res);
			} else if(req.method == HTTPMethod.MOVE) {
				dav.move(req, res);
			} else {
				res.statusCode = HTTPStatus.notImplemented;
				res.writeBody("", "text/plain");
			}
		} catch(DavException e) {
			writeln("ERROR:",e.status.to!int, "(", e.status, ") - ", e.msg);

			res.statusCode = e.status;
			res.writeBody(e.msg, e.mime);
		}

		writeln("SUCCESS:", res.statusCode.to!int, "(", res.statusCode, ")");
	}

	return &callback;
}
