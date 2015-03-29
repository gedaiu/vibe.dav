/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.filedav;

import vibedav.base;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.utils.dictionarylist;
import vibe.stream.stdio;
import vibe.stream.memory;
import vibe.utils.memory;

import std.conv : to;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.string;
import std.stdio;
import std.typecons;
import std.uri;
import std.uuid;

import tested: testName = name;

/// Compute a file etag
string eTag(string path) {
	import std.digest.crc;
	import std.stdio;

	string fileHash = path;

	if(!path.isDir) {
		auto f = File(path, "r");
		foreach (ubyte[] buffer; f.byChunk(4096)) {
			ubyte[4] hash = crc32Of(buffer);
			fileHash ~= crcHexString(hash);
	    }
	}

	fileHash ~= path.lastModified.toISOExtString ~ path.contentLength.to!string;

	auto etag = hexDigest!MD5(path ~ fileHash);
	return etag.to!string;
}

SysTime lastModified(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.timeModified.toUTC;
}

SysTime creationDate(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.timeCreated.toUTC;
}

ulong contentLength(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.size;
}

FileStream toStream(string path) {
	return openFile(path);
}

DavResource[] getFolderContent(T)(string path, URL url, DavFs!T dav, ulong depth = 1) {
	DavResource[] list;

	if(depth == 0) return list;

	auto fileList = dirEntries(path, "*", SpanMode.shallow);

	foreach(file; fileList) {
		string fileName = baseName(file.name);

		URL childUrl = url;
		childUrl.path = childUrl.path ~ fileName;

   		auto resource = new T(dav, childUrl);

   		list ~= resource;

   		if(resource.isCollection && depth > 0)
   			list ~= resource.getChildren(depth - 1);
	}

	return list;
}

/// Represents a file or directory DAV resource
class DavFileResource : DavResource {
	alias DavFsType = DavFs!DavFileResource;

	protected {
		immutable Path filePath;
		immutable string nativePath;
		DavFsType dav;
	}

	this(DavFsType dav, URL url) {
		super(dav, url);

		this.dav = dav;
		auto path = url.path;

		path.normalize;

		filePath = dav.filePath(url);
		nativePath = filePath.toNativeString();

		if(!nativePath.exists)
			throw new DavException(HTTPStatus.notFound, "File not found.");

		href = path.toString;
	}

	@property {
		string eTag() {
			return nativePath.eTag;
		}

		string contentType() {
			return getMimeTypeForFile(nativePath);
		}

		SysTime creationDate() {
			return nativePath.creationDate;
		}

		SysTime lastModified() {
			return nativePath.lastModified;
		}

		ulong contentLength() {
			return nativePath.contentLength;
		}

		bool isCollection() {
			return nativePath.isDir;
		}

		override InputStream stream() {
			return nativePath.toStream;
		}
	}

	override DavResource[] getChildren(ulong depth = 1) {
		DavResource[] list;

		string listPath = nativePath.decode;

		return getFolderContent(listPath, url, dav, depth);
	}

	override void remove() {
		super.remove;

		if(isCollection) {
			auto childList = getChildren;

			foreach(c; childList)
				c.remove;

			nativePath.rmdir;
		} else
			nativePath.remove;
	}

	@testName("exists")
	unittest {
		"level1/level2".mkdirRecurse;

		auto dav = new DavFs!DavFileResource( "/", "./" );
		auto file = dav.getResource(URL("http://127.0.0.1/level1/"));
		file.remove;

		assert(!"level1".exists);
	}

	override {
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

void serveDavFs(T)(URLRouter router, string rootUrl, string rootPath, IDavUserCollection userCollection) {
	auto fileDav = new DavFs!T(rootUrl, rootPath);
	fileDav.userCollection = userCollection;
	router.any(rootUrl ~ "*", serveDav(fileDav));
}
