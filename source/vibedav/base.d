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

import std.conv : to;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;

/// Represents a general DAV resource
class DavResource {
	string href;
	string[string] properties;
	HTTPStatus statusCode;
	bool isCollection;

	string propXmlString() {
		string str = `<d:href>` ~ href ~ `</d:href>`;
		str ~= `<d:propstat><d:prop>`;

		foreach(key, val; properties) {
			str ~= `<` ~ key ~ `>` ~ val ~ `</` ~ key ~ `>`;
		}

		if(isCollection)
			str ~= `<d:resourcetype><d:collection /></d:resourcetype>`;
		else
			str ~= `<d:resourcetype />`;


		str ~= `</d:prop></d:propstat>`;
		str ~= `<d:status>HTTP/1.1 ` ~ statusCode.to!string ~ ` ` ~ httpStatusText(statusCode) ~ `</d:status>`;

		return str;
	}
}

/// Represents a file or directory DAV resource
class DavFileResource : DavResource {
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
		isCollection = pathstr.isDir;

		auto etag = "\"" ~ hexDigest!MD5(pathstr ~ ":" ~ lastModified ~ ":" ~ to!string(dirent.size)).idup ~ "\"";

		string resType = "";
		properties["d:getetag"] = etag[1..$-1];
		properties["d:getlastmodified"] = lastModified;

		if(!isCollection) {
			properties["d:getcontentlength"] = dirent.size.to!string;
			properties["d:getcontenttype"] = getMimeTypeForFile(pathstr);
		}

		href = path.toString;

		statusCode = HTTPStatus.OK;
	}

	DavResource[] getChildren(ulong depth = 1) {
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
		string str = `<?xml version="1.0" encoding="UTF-8"?>`;
		str ~= `<d:multistatus xmlns:d="DAV:">`;

		foreach(res; list)
			str ~= `<d:response>` ~ res.propXmlString ~ `</d:response>`;

		str ~= `</d:multistatus>`;

		return str;
	}
}

/// The main DAV protocol implementation
class Dav {
	Path root;
	enum InfiniteDepth = 99;

	void options(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;

		res.headers["Accept-Ranges"] = "bytes";
		res.headers["DAV"] = "1,2,3";
		res.headers["Allow"] = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, LOCK, UNLOCK";
		res.headers["MS-Author-Via"] = "DAV";

		res.writeBody("", "text/plain");
	}

	private ulong getDepth(HTTPServerRequest req) {

		if("depth" in req.headers) {
			string strDepth = req.headers["depth"];

			if(strDepth == "infinite") return InfiniteDepth;
			if(strDepth == "1") return 1;
		} else {
			return InfiniteDepth;
		}

		return 0;
	}

	void propfind(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;
		ulong depth = getDepth(req);

		auto selectedResource = new DavFileResource(root, Path(path));

		auto response = new PropfindResponse();
		response.list = selectedResource ~ selectedResource.getChildren(depth);

		res.writeBody(response.toString, "application/xml");
	}

	void get(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;
		sendRawFile(req, res, root ~ path[1..$], new HTTPFileServerSettings);
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
			res.statusCode = HTTPStatus.multiStatus;
		} else if(req.method == HTTPMethod.GET) {
			dav.get(req, res);
			res.statusCode = HTTPStatus.ok;
		} else {
			res.statusCode = HTTPStatus.notImplemented;
			res.writeBody("", "text/plain");
		}
	}

	return &callback;
}

class FileDav : Dav {

}

HTTPServerRequestDelegate serveFileDav(Path path) {
	return serveDav!FileDav(path);
}
