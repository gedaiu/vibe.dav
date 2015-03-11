/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 15, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.util;

import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;

import vibe.core.log;
import vibe.core.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.conv : to;


string getEtag(Path path) {
	auto pathstr = path.toNativeString();

	FileInfo dirent;
	try dirent = getFileInfo(pathstr);
	catch(Exception){
		throw new HTTPStatusException(HTTPStatus.InternalServerError, "Failed to get information for the file due to a file system error.");
	}

	auto lastModified = toRFC822DateTimeString(dirent.timeModified.toUTC());

	auto etag = hexDigest!MD5(pathstr ~ ":" ~ lastModified ~ ":" ~ to!string(dirent.size)).idup;

	return etag;
}

/// Copied from vibe. Do some refactor maybe, include this in the framework
void sendRawFile(HTTPServerRequest req, HTTPServerResponse res, Path path, HTTPFileServerSettings settings, bool sendHeadersOnly = false)
{
	auto pathstr = path.toNativeString();

	// return if the file does not exist
	if( !existsFile(pathstr) ){
		if( settings.failIfNotFound ) throw new HTTPStatusException(HTTPStatus.NotFound);
		else return;
	}

	FileInfo dirent;
	try dirent = getFileInfo(pathstr);
	catch(Exception){
		throw new HTTPStatusException(HTTPStatus.InternalServerError, "Failed to get information for the file due to a file system error.");
	}

	if (dirent.isDirectory) {
		logDebugV("Hit directory when serving files, ignoring: %s", pathstr);
		if( settings.failIfNotFound ) throw new HTTPStatusException(HTTPStatus.NotFound);
		else return;
	}

	auto lastModified = toRFC822DateTimeString(dirent.timeModified.toUTC());
	// simple etag generation
	auto etag = "\"" ~ getEtag(path) ~ "\"";

	res.headers["Last-Modified"] = lastModified;
	res.headers["Etag"] = etag;
	if (settings.maxAge > seconds(0)) {
		auto expireTime = Clock.currTime(UTC()) + settings.maxAge;
		res.headers["Expires"] = toRFC822DateTimeString(expireTime);
		res.headers["Cache-Control"] = "max-age="~to!string(settings.maxAge.total!"seconds");
	}

	if( auto pv = "If-Modified-Since" in req.headers ) {
		if( *pv == lastModified ) {
			res.statusCode = HTTPStatus.NotModified;
			res.writeVoidBody();
			return;
		}
	}

	if( auto pv = "If-None-Match" in req.headers ) {
		if ( *pv == etag ) {
			res.statusCode = HTTPStatus.NotModified;
			res.writeVoidBody();
			return;
		}
	}

	auto mimetype = getMimeTypeForFile(pathstr);
	// avoid double-compression
	if ("Content-Encoding" in res.headers && isCompressedFormat(mimetype))
		res.headers.remove("Content-Encoding");
	res.headers["Content-Type"] = mimetype;
	res.headers["Content-Length"] = to!string(dirent.size);

	// check for already encoded file if configured
	string encodedFilepath;
	auto pce = "Content-Encoding" in res.headers;
	if (pce) {
		if (auto pfe = *pce in settings.encodingFileExtension) {
			assert((*pfe).length > 0);
			auto p = pathstr ~ *pfe;
			if (existsFile(p))
				encodedFilepath = p;
		}
	}
	if (encodedFilepath.length) {
		auto origLastModified = dirent.timeModified.toUTC();

		try dirent = getFileInfo(encodedFilepath);
		catch(Exception){
			throw new HTTPStatusException(HTTPStatus.InternalServerError, "Failed to get information for the file due to a file system error.");
		}

		// encoded file must be younger than original else warn
		if (dirent.timeModified.toUTC() >= origLastModified){
			logTrace("Using already encoded file '%s' -> '%s'", path, encodedFilepath);
			path = Path(encodedFilepath);
			res.headers["Content-Length"] = to!string(dirent.size);
		} else {
			logWarn("Encoded file '%s' is older than the original '%s'. Ignoring it.", encodedFilepath, path);
			encodedFilepath = null;
		}
	}

	if(settings.preWriteCallback)
		settings.preWriteCallback(req, res, pathstr);

	// for HEAD responses, stop here
	if( res.isHeadResponse() ){
		res.writeVoidBody();
		assert(res.headerWritten);
		logDebug("sent file header %d, %s!", dirent.size, res.headers["Content-Type"]);
		return;
	}

	// else write out the file contents
	//logTrace("Open file '%s' -> '%s'", srv_path, pathstr);
	FileStream fil;
	try {
		fil = openFile(path);
	} catch( Exception e ){
		// TODO: handle non-existant files differently than locked files?
		logDebug("Failed to open file %s: %s", pathstr, e.toString());
		return;
	}
	scope(exit) fil.close();

	if(!sendHeadersOnly) {
		if (pce && !encodedFilepath.length)
			res.bodyWriter.write(fil);
		else res.writeRawBody(fil);
	}

	logTrace("sent file %d, %s!", fil.size, res.headers["Content-Type"]);
}
