/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.filedav;

public import vibedav.base;

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

		properties["d:creationdate"] = new DavProp(nativePath.creationDate.toRFC822DateTimeString);

		if(nativePath.isDir)
			isCollection = true;
		else
			properties["d:getcontenttype"] = new DavProp(getMimeTypeForFile(nativePath));

		href = path.toString;
	}

	@property override {
		string eTag() {
			return nativePath.eTag;
		}

		string mimeType() {
			return getMimeTypeForFile(nativePath);
		}

		SysTime lastModified() {
			return nativePath.lastModified;
		}

		ulong contentLength() {
			return nativePath.contentLength;
		}

		InputStream stream() {
			return nativePath.toStream;
		}
	}

	override DavResource[] getChildren(ulong depth = 1) {
		DavResource[] list;

		if(depth == 0) return list;
		string listPath = filePath.toString.decode;
		string rootPath = dav.rootFile.toString.decode;

		auto fileList = dirEntries(listPath, "*", SpanMode.shallow);

		foreach(file; fileList) {
			string fileName = baseName(file.name);

			URL childUrl = url;
			childUrl.path = childUrl.path ~ fileName;

	   		auto resource = new DavFileResource(this.dav, childUrl);

	   		list ~= resource;

	   		if(resource.isCollection && depth > 0)
	   			list ~= resource.getChildren(depth - 1);
		}

		return list;
	}

	override void remove() {
		super.remove;

		if(isCollection) {
			auto childList = getChildren;

			foreach(c; childList)
				c.remove;

			filePath.toString.rmdir;
		} else
			filePath.toString.remove;
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
			immutable string p = filePath.to!string;
			std.stdio.write(p, content);
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
