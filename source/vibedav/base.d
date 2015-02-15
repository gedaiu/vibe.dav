/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 15, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */

module vibedav.base;

public import vibedav.util;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;

import kxml.xml;

import std.conv : to;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.string;
import std.stdio; //todo: remove this

/// Represents a general DAV resource
class DavResource {
	string href;
	string[string] properties;
	HTTPStatus statusCode;
	bool isCollection;

	string propXmlString(bool[string] props = cast(bool[string])[]) {
		string str = `<d:href>` ~ href ~ `</d:href>`;
		str ~= `<d:propstat><d:prop>`;

		foreach(key, val; properties) {
			auto key1 = key.toLower;

			if(props.length == 0 || props.length > 0 && (key1 in props) !is null)
				str ~= `<` ~ key ~ `>` ~ val ~ `</` ~ key ~ `>`;

		}

		if(props.length == 0 || (props.length > 0 && ("d:resourcetype" in props) !is null)) {
			if(isCollection)
				str ~= `<d:resourcetype><d:collection /></d:resourcetype>`;
			else
				str ~= `<d:resourcetype />`;
		}

		str ~= `</d:prop></d:propstat>`;
		str ~= `<d:status>HTTP/1.1 ` ~ statusCode.to!string ~ ` ` ~ httpStatusText(statusCode) ~ `</d:status>`;

		return str;
	}

	abstract DavResource[] getChildren(ulong depth = 1);
}

/// Represents a file or directory DAV resource
final class DavFileResource : DavResource {
	private immutable Path resPath;
	private immutable Path fileRoot;
	private immutable Path filePath;

	this(Path root, Path path) {
		path.normalize;
		root.normalize;

		logTrace("create DAV file resource %s %s", root , path);

		resPath = path;
		fileRoot = root;
		filePath = root ~ path.toString[1..$];

		FileInfo dirent;
		auto pathstr = filePath.toNativeString();

		try dirent = getFileInfo(pathstr);
		catch(Exception){
			throw new HTTPStatusException(HTTPStatus.InternalServerError,
				"Failed to get information for the file due to a file system error.");
		}

		auto lastModified = toRFC822DateTimeString(dirent.timeModified.toUTC());
		auto creationDate = toRFC822DateTimeString(dirent.timeCreated.toUTC());
		isCollection = pathstr.isDir;

		auto etag = "\"" ~ hexDigest!MD5(pathstr ~ ":" ~ lastModified ~ ":" ~ to!string(dirent.size)).idup ~ "\"";

		string resType = "";
		properties["d:getetag"] = etag[1..$-1];
		properties["d:getlastmodified"] = lastModified;
		properties["d:creationdate"] = creationDate;

		if(!isCollection) {
			properties["d:getcontentlength"] = dirent.size.to!string;
			properties["d:getcontenttype"] = getMimeTypeForFile(pathstr);
		}

		href = path.toString;

		statusCode = HTTPStatus.OK;
	}

	override DavResource[] getChildren(ulong depth = 1) {
		DavResource[] list;

		if(depth == 0) return list;
		string listPath = filePath.toString;
		string rootPath = fileRoot.toString;

		auto fileList = dirEntries( listPath, "*", SpanMode.shallow);

		foreach(file; fileList) {
			string path = file.name[rootPath.length..$];

			if(path[0] != '/')
				path = "/" ~ path;

	   		auto resource = new DavFileResource( fileRoot, Path(path) );

	   		list ~= resource;

	   		if(resource.isCollection && depth > 0)
	   			list ~= resource.getChildren(depth - 1);
		}

		return list;
	}

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
		str ~= `<d:multistatus xmlns:d="DAV:">`;

		foreach(res; list)
			str ~= `<d:response>` ~ res.propXmlString(props) ~ `</d:response>`;

		str ~= `</d:multistatus>`;

		return str;
	}
}

/// The main DAV protocol implementation
abstract class Dav {
	Path root;
	enum InfiniteDepth = 99;

	abstract DavResource getResource(Path url);
	abstract HTTPStatus createCollection(Path url);

	void options(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;

		res.headers["Accept-Ranges"] = "bytes";
		res.headers["DAV"] = "1,2,3";
		res.headers["Allow"] = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, LOCK, UNLOCK";
		res.headers["MS-Author-Via"] = "DAV";

		res.writeBody("", "text/plain");
	}

	private {
		ulong getDepth(HTTPServerRequest req) {

			if("depth" in req.headers) {
				string strDepth = req.headers["depth"];

				if(strDepth == "infinite") return InfiniteDepth;
				if(strDepth == "1") return 1;
			} else {
				return InfiniteDepth;
			}

			return 0;
		}

		bool[string] propList(XmlNode document) {
			bool[string] list;

			XmlNode[] prop = document.parseXPath("d:propfind/d:prop");

			if(prop.length > 0) {
				auto properties = prop[0].getChildren;

				foreach(p; properties)
					list[p.getName.toLower] = true;
			}
			return list;
		}
	}

	void propfind(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;
		ulong depth = getDepth(req);
		bool[string] properties;

		string requestXml = cast(string)req.bodyReader.readAllUTF8;

		if(requestXml.length > 0) {
			XmlNode document = readDocument(requestXml);
			properties = propList(document);
		}

		auto selectedResource = getResource(Path(path));

		auto response = new PropfindResponse();
		response.list = selectedResource ~ selectedResource.getChildren(depth);

		res.statusCode = HTTPStatus.multiStatus;

		if(properties.length == 0)
			res.writeBody(response.toString, "application/xml");
		else
			res.writeBody(response.toStringProps(properties), "application/xml");

	}

	void get(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;
		res.statusCode = HTTPStatus.ok;
		sendRawFile(req, res, root ~ path[1..$], new HTTPFileServerSettings);
	}

	void mkcol(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;

		res.statusCode = createCollection(Path(path));
		res.writeBody("", "text/plain");
	}
}

/// File dav impplementation
class FileDav : Dav {
	override DavResource getResource(Path url) {
		return new DavFileResource(root, url);
	}

	override HTTPStatus createCollection(Path url) {
		auto filePath = root ~ url.to!string[1..$];

		if(filePath.toString.exists)
			return HTTPStatus.methodNotAllowed;

		mkdir(filePath.toString);

		return HTTPStatus.created;
	}
}

HTTPServerRequestDelegate serveDav(T : Dav)(Path path) {
	auto dav = new T;
	dav.root = path;

	void callback(HTTPServerRequest req, HTTPServerResponse res)
	{
		if(req.method == HTTPMethod.OPTIONS) {
			dav.options(req, res);
		} else if(req.method == HTTPMethod.PROPFIND) {
			dav.propfind(req, res);
		} else if(req.method == HTTPMethod.GET) {
			dav.get(req, res);
		} else if(req.method == HTTPMethod.MKCOL) {
			dav.mkcol(req, res);
		} else {
			res.statusCode = HTTPStatus.notImplemented;
			res.writeBody("", "text/plain");
		}
	}

	return &callback;
}

HTTPServerRequestDelegate serveFileDav(Path path) {
	return serveDav!FileDav(path);
}
