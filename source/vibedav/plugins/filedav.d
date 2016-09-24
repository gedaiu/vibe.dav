/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.plugins.filedav;

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
import std.exception;

static if (__traits(compiles, { import std.algorithm.comparison : max; }))
    import std.algorithm.comparison : max;
else
    import std.algorithm;

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

Path[] getFolderContent(string format = "*")(string path, Path rootPath, Path rootUrl) {
	Path[] list;
	rootPath.endsWithSlash = true;
	string strRootPath = rootPath.toString;

	auto p = Path(path);
	p.endsWithSlash = true;
	path = p.toString;

	enforce(path.isDir, "I was expecting to get a dir content");
	enforce(strRootPath.length <= path.length);
	enforce(strRootPath == path[0..strRootPath.length]);

	auto fileList = dirEntries(path, format, SpanMode.shallow);

  foreach(file; fileList) {
		auto filePath = Path(file[strRootPath.length..$]);
		filePath.endsWithSlash = false;

    list ~= filePath;
	}

	return list;
}

class DirectoryResourcePlugin : IDavResourcePlugin {
	private {
		Path baseUrlPath;
		Path basePath;
	}

	this(Path baseUrlPath, Path basePath) {
		this.baseUrlPath = baseUrlPath;
		this.basePath = basePath;
	}

	Path filePath(URL url) {
		return getFilePath(baseUrlPath, basePath, url);
	}

	pure nothrow {
		bool canSetContent(DavResource resource) {
			return false;
		}

		bool canGetStream(DavResource resource) {
			return false;
		}

		bool canGetProperty(DavResource resource, string name) {
			return false;
		}

		bool canSetProperty(DavResource resource, string name) {
			return false;
		}

		bool canRemoveProperty(DavResource resource, string name) {
			return false;
		}
	}

	void setContent(DavResource resource, const ubyte[] content) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set directory stream.");
	}

	void setContent(DavResource resource, InputStream content, ulong size) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set directory stream.");
	}

	InputStream stream(DavResource resource) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get directory stream.");
	}

	void copyPropertiesTo(URL source, URL destination) {

	}

	DavProp property(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
	}

	HTTPStatus setProperty(DavResource resource, string name, DavProp prop) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set property.");
	}

	HTTPStatus removeProperty(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove property.");
	}

	pure nothrow @property {
		string name() {
			return "DirectoryResourcePlugin";
		}
	}
}

class FileResourcePlugin : IDavResourcePlugin {
	private {
		Path baseUrlPath;
		Path basePath;
	}

	this(Path baseUrlPath, Path basePath) {
		this.baseUrlPath = baseUrlPath;
		this.basePath = basePath;
	}

	Path filePath(URL url) {
		return getFilePath(baseUrlPath, basePath, url);
	}

	bool canSetContent(DavResource resource) {
		auto filePath = filePath(resource.url).toString;
		return filePath.exists;
	}

	bool canGetStream(DavResource resource) {
		return canSetContent(resource);
	}

	bool canGetProperty(DavResource resource, string name) {
		return false;
	}

	bool canSetProperty(DavResource resource, string name) {
		return false;
	}

	bool canRemoveProperty(DavResource resource, string name) {
		return false;
	}

	void setContent(DavResource resource, const ubyte[] content) {
		auto filePath = filePath(resource.url).toString;
		std.stdio.write(filePath, content);
	}

	void setContent(DavResource resource, InputStream content, ulong size) {
		auto nativePath = filePath(resource.url).toString;

		auto tmpPath = nativePath ~ ".tmp";
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

	InputStream stream(DavResource resource) {
		auto nativePath = filePath(resource.url).toString;
		return nativePath.toStream;
	}

	DavProp property(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
	}

	void copyPropertiesTo(URL source, URL destination) {

	}

	HTTPStatus setProperty(DavResource resource, string name, DavProp prop) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set property.");
	}

	HTTPStatus removeProperty(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove property.");
	}

	pure nothrow @property {
		string name() {
			return "FileResourcePlugin";
		}
	}
}

/// File Dav impplementation
class FileDav : BaseDavPlugin {

	protected {
		Path baseUrlPath;
		Path basePath;
	}

	this(IDav dav, Path baseUrlPath, Path basePath) {
		super(dav);
		this.baseUrlPath = baseUrlPath;
		this.basePath = basePath;
	}

	protected {
		void setResourceProperties(DavResource resource) {
			string path = filePath(resource.url).toString;
			assert(path.exists, "Can't set basic properties. The path does not exist.");

			setResourceInfoProperties(resource);

			if(path.isDir)
				setCollection(resource);
		}

		void setCollection(DavResource resource) {
			resource.resourceType ~= "collection:DAV:";
		}

		void setResourceInfoProperties(DavResource resource) {
			string path = filePath(resource.url).toString;

			assert(path.exists);

			resource.creationDate = creationDate(path);
			resource.lastModified = lastModified(path);
			resource.eTag = eTag(path);
			resource.contentType = getMimeTypeForFile(path);
			resource.contentLength = contentLength(path);
			resource.name = baseName(path);
		}
	}

	Path filePath(URL url) {
		return getFilePath(baseUrlPath, basePath, url);
	}

	override {
		bool exists(URL url, string username) {
			auto filePath = filePath(url);

			return filePath.toString.exists;
		}


  	Path[] childList(URL url, string username) {
  		Path[] list;

  		auto nativePath = filePath(url).toString;

  		if(nativePath.exists)
  			list = getFolderContent!"*"(nativePath, basePath, baseUrlPath);

  		return list;
  	}


		bool canCreateResource(URL url, string username) {
			return !exists(url, username);
		}

		bool canCreateCollection(URL url, string username) {
			return !exists(url, username);
		}

		void removeResource(URL url, string username) {
			if(!exists(url, username))
				throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

			auto filePath = filePath(url).toString;

			if(filePath.isDir)
				filePath.rmdirRecurse;
			else
				filePath.remove;
		}

		DavResource getResource(URL url, string username) {
			if(!exists(url, username))
				throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

			auto filePath = filePath(url);

			DavResource resource = new DavResource(_dav, url);
			resource.username = username;
			setResourceProperties(resource);

			return resource;
		}

		DavResource createResource(URL url, string username) {
			auto filePath = filePath(url).toString;

			File(filePath, "w");

			return getResource(url, username);
		}

		DavResource createCollection(URL url, string username) {
			auto filePath = filePath(url);

			if(filePath.toString.exists)
				throw new DavException(HTTPStatus.methodNotAllowed, "Resource already exists.");

			filePath.toString.mkdirRecurse;

			return getResource(url, username);
		}

		void bindResourcePlugins(DavResource resource) {
			if(resource.isCollection)
				resource.registerPlugin(new DirectoryResourcePlugin(baseUrlPath, basePath));
			else
				resource.registerPlugin(new FileResourcePlugin(baseUrlPath, basePath));

			resource.registerPlugin(new ResourceCustomProperties);
			resource.registerPlugin(new ResourceBasicProperties);
		}

		@property {
			IDav dav() {
				return _dav;
			}

			string[] support(URL url, string username) {
				return ["1", "2", "3"];
			}
		}
	}

	@property {
		string name() {
			return "FileDav";
		}
	}
}

IDav serveFileDav(URLRouter router, string rootUrl, string rootPath) {
	rootUrl = rootUrl.stripSlashes;
	rootPath = rootPath.stripSlashes;

	auto dav = new Dav(rootUrl);
	auto fileDav = new FileDav(dav, Path(rootUrl), Path(rootPath));

	if(rootUrl != "") rootUrl = "/"~rootUrl~"/";

	router.any(rootUrl ~ "*", serveDav(dav));

	return dav;
}
