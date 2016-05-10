/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 29, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.davresource;

import vibedav.prop;

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
import std.stdio;
import std.datetime;
import std.string;
import std.file;
import std.path;

struct ResourcePropertyValue {
	enum Mode {
		none,
		attribute,
		tagName,
		tagAttributes,
		tag,
		levelTag
	}

	string name;
	string name2;
	string ns;
	string attr;
	Mode mode;

	DavProp create(string val) {
		if(mode == Mode.attribute)
			return createAttribute(val);

		if(mode == Mode.tagName)
			return createTagName(val);

		if(mode == Mode.tag)
			return createTagText(val);

		if(mode == Mode.levelTag)
			return createLevelTag(val);

		return new DavProp(val);
	}

	DavProp create(string[string] val) {
		if(mode == Mode.tagAttributes)
			return createTagList(val);

		throw new DavException(HTTPStatus.internalServerError, "Can't parse value.");
	}

	DavProp createAttribute(string val) {
		DavProp p = new DavProp(ns, name);
		p.attribute[attr] = val;

		return p;
	}

	DavProp createTagName(string val) {
		return DavProp.FromKey(val, "");
	}

	DavProp createTagList(string[string] val) {
		DavProp p = new DavProp(ns, name);

		foreach(k, v; val)
			p.attribute[k] = v;

		return p;
	}

	DavProp createLevelTag(string val) {
		DavProp level1 = new DavProp(ns, name);
		DavProp level2 = new DavProp(ns, name2);

		level2.addChild(DavProp.FromKey(val, ""));
		level1.addChild(level2);

		return level1;
	}

	DavProp createTagText(string val) {
		return new DavProp(ns, name, val);
	}
}

/// Make the returned value to be rendered like this: <[name] xmlns="[ns]" [attr]=[value]/>
ResourcePropertyValue ResourcePropertyValueAttr(string name, string ns, string attr) {
	ResourcePropertyValue v;
	v.name = name;
	v.ns = ns;
	v.attr = attr;
	v.mode = ResourcePropertyValue.Mode.attribute;

	return v;
}

/// Make the returned value to be a <collection> tag or not
ResourcePropertyValue ResourcePropertyTagName() {
	ResourcePropertyValue v;
	v.mode = ResourcePropertyValue.Mode.tagName;

	return v;
}

/// Make the returned value to be <[name] xmlns=[ns] [attribute list]/>
ResourcePropertyValue ResourcePropertyTagAttributes(string name, string ns) {
	ResourcePropertyValue v;
	v.name = name;
	v.ns = ns;
	v.mode = ResourcePropertyValue.Mode.tagAttributes;

	return v;
}

/// Make the returned value to be: <[name] xmlns=[ns]>[value]</[name]>
ResourcePropertyValue ResourcePropertyTagText(string name, string ns) {
	ResourcePropertyValue v;
	v.name = name;
	v.ns = ns;
	v.mode = ResourcePropertyValue.Mode.tag;

	return v;
}

/// Make the returned value to be: <[level1Name] xmlns=[ns]><[level2Name] xmlns=[ns]><value></[level2Name]></[level1Name]>
ResourcePropertyValue ResourcePropertyLevelTagText(string level1Name, string level2Name, string ns) {
	ResourcePropertyValue v;
	v.name  = level1Name;
	v.name2 = level2Name;
	v.ns = ns;
	v.mode = ResourcePropertyValue.Mode.levelTag;

	return v;
}

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
		return getResourceProperty!(T[1..$]);
}

ResourcePropertyValue getResourceTagProperty(T...)() {
	static if(T.length == 0) {
		ResourcePropertyValue v;
		return v;
	}
	else static if( is(typeof(T[0]) == ResourcePropertyValue) )
		return T[0];
	else
		return getResourceTagProperty!(T[1..$]);
}

pure bool hasDavInterfaceProperty(I)(string key) {
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

DavProp propFrom(T, U)(string name, string ns, T value, U tagVal) {
	string v;

	auto p = new DavProp(ns, name);

	static if( is(T == SysTime) )
	{
		auto elm = tagVal.create(toRFC822DateTimeString(value));
		p.addChild(elm);
	}
	else static if( is(T == string[]) )
	{
		foreach(item; value) {
			auto tag = tagVal.create(item);

			try
				p.addChild(tag);
			catch(Exception e)
				writeln(e);
		}
	}
	else static if( is(T == string[][string]) )
	{
		foreach(item; value) {
			auto tag = tagVal.create(item);
			p.addChild(tag);
		}
	}
	else
	{
		auto elm = tagVal.create(value.to!string);
		p.addChild(elm);
	}

	return p;
}

DavProp getDavInterfaceProperty(I, T)(string key, T plugin, DavResource resource) {
	DavProp result;

	void getProp(T...)() {
		static if(T.length > 0) {
			enum val = getResourceProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum tagVal = getResourceTagProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum staticKey = val.name ~ ":" ~ val.ns;


			if(staticKey == key) {
				auto value = __traits(getMember, plugin, T[0])(resource);
				result = propFrom(val.name, val.ns, value, tagVal);
			}

			getProp!(T[1..$])();
		}
	}

	getProp!(__traits(allMembers, I))();

	return result;
}

enum DavDepth : int {
	zero = 0,
	one = 1,
	infinity = 99
};

interface IDavBindingProperties {

	@property {

		@ResourceProperty("resource-id", "DAV:")
		string resourceId(DavResource resource);
	}
}

interface IDavReportSetProperties {

	@property {

		@ResourcePropertyLevelTagText("supported-report", "report", "DAV:")
		@ResourceProperty("supported-report-set", "DAV:")
		string[] supportedReportSet(DavResource resource);
	}
}

interface IDavResourceProperties {
	@ResourceProperty("creationdate", "DAV:")
	SysTime creationDate(DavResource resource);

	@ResourceProperty("getlastmodified", "DAV:")
	SysTime lastModified(DavResource resource);

	@ResourceProperty("getetag", "DAV:")
	string eTag(DavResource resource);

	@ResourceProperty("getcontenttype", "DAV:")
	string contentType(DavResource resource);

	@ResourceProperty("getcontentlength", "DAV:")
	ulong contentLength(DavResource resource);

	@ResourceProperty("resourcetype", "DAV:")
	@ResourcePropertyTagName()
	string[] resourceType(DavResource resource);

	@ResourceProperty("displayname", "DAV:")
	string displayName(DavResource resource);
}

interface IDavResourceExtendedProperties {

	@ResourceProperty("add-member", "DAV:")
	@ResourcePropertyTagText("href", "DAV:")
	string[] addMember();

	@ResourceProperty("owner", "DAV:")
	@ResourcePropertyTagText("href", "DAV:")
	string owner();
}

interface IDavResourcePlugin {

	bool canSetContent(DavResource resource);
	bool canGetStream(DavResource resource);
	bool canGetProperty(DavResource resource, string name);
	bool canSetProperty(DavResource resource, string name);
	bool canRemoveProperty(DavResource resource, string name);

	void setContent(DavResource resource, const ubyte[] content);
	void setContent(DavResource resource, InputStream content, ulong size);
	InputStream stream(DavResource resource);

	void copyPropertiesTo(URL source, URL destination);
	DavProp property(DavResource resource, string name);
	HTTPStatus setProperty(DavResource resource, string name, DavProp prop);
	HTTPStatus removeProperty(DavResource resource, string name);

	@property {
		string name();
	}
}

abstract class BaseDavResourcePlugin : IDavResourcePlugin {

	bool canSetContent(DavResource resource) {
		return false;
	}

	bool canGetStream(DavResource resource) {
		return false;
	}

	bool canSetProperty(DavResource resource, string name) {
		return false;
	}

	bool canRemoveProperty(DavResource resource, string name) {
		return false;
	}

	bool canGetProperty(DavResource resource, string name) {
		return false;
	}

	void setContent(DavResource resource, const ubyte[] content) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set content.");
	}

	void setContent(DavResource resource, InputStream content, ulong size) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set content.");
	}

	InputStream stream(DavResource resource) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get stream.");
	}

	void copyPropertiesTo(URL source, URL destination) { }

	DavProp property(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
	}

	HTTPStatus setProperty(DavResource resource, string name, DavProp prop) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set property.");
	}

	HTTPStatus removeProperty(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove property.");
	}
}

interface IDavResourcePluginHub {
	void registerPlugin(IDavResourcePlugin plugin);
	bool hasPlugin(string name);
}

class ResourceBasicProperties : BaseDavResourcePlugin, IDavResourceProperties {

	SysTime creationDate(DavResource resource) {
		return resource.creationDate;
	}

	SysTime lastModified(DavResource resource) {
		return resource.lastModified;
	}

	string eTag(DavResource resource) {
		return resource.eTag;
	}

	string contentType(DavResource resource) {
		return resource.contentType;
	}

	ulong contentLength(DavResource resource) {
		return resource.contentLength;
	}

	string[] resourceType(DavResource resource) {
		return resource.resourceType;
	}

	string displayName(DavResource resource) {
		return resource.name;
	}

	override {
		bool canGetProperty(DavResource resource, string name) {
			if(hasDavInterfaceProperty!IDavResourceProperties(name))
				return true;

			return false;
		}

		DavProp property(DavResource resource, string name) {

			if(canGetProperty(resource, name))
				return getDavInterfaceProperty!IDavResourceProperties(name, this, resource);

			throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
		}
	}

	@property {
		string name() {
			return "ResourceBasicProperties";
		}
	}
}

class ResourceCustomProperties : BaseDavResourcePlugin {

	private static DavProp[string][string] properties;

	override {
		bool canGetProperty(DavResource resource, string name) {
			string u = resource.url.toString;

			if(u !in properties)
				return false;

			if(name !in properties[u])
				return false;

			return true;
		}

		bool canSetProperty(DavResource resource, string name) {
			return true;
		}

		bool canRemoveProperty(DavResource resource, string name) {
			return canGetProperty(resource, name);
		}

		void copyPropertiesTo(URL source, URL destination) {
			if(source.toString in properties)
				properties[destination.toString] = properties[source.toString];
		}

		DavProp property(DavResource resource, string name) {
			if(canGetProperty(resource, name))
				return properties[resource.url.toString][name];

			throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
		}

		HTTPStatus setProperty(DavResource resource, string name, DavProp prop) {
			if(resource.url.toString !in properties) {
				DavProp[string] list;
				properties[resource.url.toString] = list;
			}

			properties[resource.url.toString][name] = prop;

			return HTTPStatus.ok;
		}

		HTTPStatus removeProperty(DavResource resource, string name) {
			if(canGetProperty(resource, name))
				properties[resource.url.toString].remove(name);

			return HTTPStatus.notFound;
		}
	}

	@property {
		string name() {
			return "ResourceCustomProperties";
		}
	}
}

/// Represents a DAV resource
class DavResource : IDavResourcePluginHub {
	string href;
	URL url;
	string username;

	SysTime creationDate;
	SysTime lastModified;
	string eTag;
	string contentType;
	ulong contentLength;
	string[] resourceType;
	string name;

	protected {
		IDavResourcePlugin[] plugins;
		IDav dav;
	}

	this(IDav dav, URL url) {
		this.dav = dav;
		this.url = url;

		resourceType = [];

		creationDate = Clock.currTime;
		lastModified = Clock.currTime;
	}

	private {
		HTTPStatus removeProperty(string key) {
			HTTPStatus result = HTTPStatus.notFound;

			foreach_reverse(plugin; plugins)
				if(plugin.canRemoveProperty(this, key))
					try plugin.removeProperty(this, key);
						catch (DavException e)
							result = e.status;

			foreach_reverse(plugin; plugins)
				if(plugin.canGetProperty(this, key))
					result = HTTPStatus.ok;

			return result;
		}

		HTTPStatus setProperty(string key, DavProp prop) {
			HTTPStatus result = HTTPStatus.notFound;

			foreach_reverse(plugin; plugins)
				if(plugin.canSetProperty(this, key))
					try plugin.setProperty(this, key, prop);
						catch (DavException e)
							result = e.status;

			foreach_reverse(plugin; plugins)
				if(plugin.canGetProperty(this, key))
					result = HTTPStatus.ok;

			return result;
		}
	}

	void registerPlugin(IDavResourcePlugin plugin) {
		assert(!hasPlugin(plugin.name), plugin.name ~ " already added.");
		plugins ~= plugin;
	}

	bool hasPlugin(string name) {

		foreach_reverse(plugin; plugins)
			if(plugin.name == name)
				return true;

		return false;
	}

	@property {
		string fullURL() {
			return url.toString;
		}

		string rootURL() {
			return dav.rootUrl.toString;
		}

		Path path() {
			return dav.path(url);
		}

		nothrow pure string type() {
			return "DavResource";
		}
	}

	DavProp property(string key) {
		DavProp p;

		foreach_reverse(plugin; plugins) {
			if(plugin.canGetProperty(this, key)) {

				auto t = plugin.property(this, key);

				if(p is null)
					p = t;
				else if(p.isGroup && t.isGroup)
					foreach(string k, DavProp child; t)
						p.addChild(child);
			}
		}

		if(p !is null)
			return p;

		throw new DavException(HTTPStatus.notFound, "Not Found");
	}

	void filterProps(DavProp parent, bool[string] props) {
		DavProp item = new DavProp;
		item.parent = parent;
		item.name = "d:response";

		DavProp[][int] result;

		item[`d:href`] = urlToString(url);

		foreach_reverse(key; props.keys) {
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
		foreach_reverse(code; result.keys) {
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

	string propPatch(DavProp document) {
		string description;
		string result = `<?xml version="1.0" encoding="utf-8" ?><d:multistatus xmlns:d="DAV:"><d:response>`;
		result ~= `<d:href>` ~ urlToString(url) ~ `</d:href>`;

		auto updateList = [document].getTagChilds("propertyupdate");

		foreach(string key, item; updateList[0]) {
			if(item.tagName == "remove") {
				//remove properties
				auto removeList = [item].getTagChilds("prop");

				foreach(prop; removeList)
					foreach(string key, p; prop) {
						auto status = removeProperty(key);
						result ~= `<d:propstat><d:prop>` ~ p.toString ~ `</d:prop>`;
						result ~= `<d:status>HTTP/1.1 ` ~ status.to!int.to!string ~ ` ` ~ status.to!string ~ `</d:status></d:propstat>`;
					}
			}
			else if(item.tagName == "set") {
				//set properties
				auto setList = [item].getTagChilds("prop");

				foreach(prop; setList) {
					foreach(string key, p; prop) {
						auto status = setProperty(key, p);
						result ~= `<d:propstat><d:prop>` ~ p.toString ~ `</d:prop>`;
						result ~= `<d:status>HTTP/1.1 ` ~ status.to!int.to!string ~ ` ` ~ status.to!string ~ `</d:status></d:propstat>`;
					}
				}
			}
		}

		if(description != "")
			result ~= `<d:responsedescription>` ~ description ~ `</d:responsedescription>`;

		result ~= `</d:response></d:multistatus>`;

		return result;
	}

	void copyPropertiesTo(URL destination) {
		foreach_reverse(plugin; plugins)
			plugin.copyPropertiesTo(url, destination);
	}

	void setContent(const ubyte[] content) {
		foreach_reverse(plugin; plugins)
			if(plugin.canSetContent(this)) {
				plugin.setContent(this, content);

				return;
			}

		throw new DavException(HTTPStatus.methodNotAllowed, "setContent No plugin support.");
	}

	void setContent(InputStream content, ulong size) {

		foreach_reverse(plugin; plugins)
			if(plugin.canSetContent(this)) {
				plugin.setContent(this, content, size);

				return;
			}

		throw new DavException(HTTPStatus.methodNotAllowed, "setContent No plugin support.");
	}

	@property {
		InputStream stream() {
			foreach_reverse(plugin; plugins)
			if(plugin.canGetStream(this))
				return plugin.stream(this);

			throw new DavException(HTTPStatus.methodNotAllowed, "stream No plugin support.");
		}

		pure nothrow bool isCollection() {
			foreach_reverse(type; resourceType)
				if(type == "collection:DAV:")
					return true;

			return false;
		}
	}
}
