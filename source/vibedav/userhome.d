/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 22, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.userhome;

import vibedav.filedav;

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

class FileDavUserHomeCollection : FileDavCollection {

	this(IFileDav davPlugin, URL url, bool forceCreate = false) {
		super(davPlugin, url, forceCreate);
	}

}
