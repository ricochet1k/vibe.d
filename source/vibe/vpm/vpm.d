/**
	A package manager.

	Copyright: © 2012 Matthias Dondorff
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Matthias Dondorff
*/
module vibe.vpm.vpm;

// todo: cleanup imports.
import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.string;
import std.typecons;
import std.zip;

import vibe.core.log;
import vibe.core.file;
import vibe.data.json;
import vibe.inet.url;

import vibe.vpm.dependency;
import vibe.vpm.installation;
import vibe.vpm.utils;
import vibe.vpm.registry;
import vibe.vpm.packagesupplier;

/// Actions to be performed by the vpm
private struct Action {
	enum ActionId {
		InstallUpdate,
		Uninstall,
		Conflict,
		Failure
	}
	
	this( ActionId id, string pkg, const Dependency d, Dependency[string] issue) {
		action = id; packageId = pkg; vers = new Dependency(d); issuer = issue;
	}
	const ActionId action;
	const string packageId;
	const Dependency vers;
	const Dependency[string] issuer;
	
	string toString() const {
		return to!string(action) ~ ": " ~ packageId ~ ", " ~ to!string(vers);
	}
}

/// During check to build task list, which can then be executed.
private class Application {
	private {
		Path m_root;
		Package m_main;
		Package[string] m_packages;
	}
	
	this(Path rootFolder) {
		m_root = rootFolder;
		reinit();
	}
	
	/// Gathers information
	string info() const {
		if(!m_main) 
			return "-Unregocgnized application in '"~to!string(m_root)~"' (properly no package.json in this directory)";
		string s = "-Application identifier: " ~ m_main.name;
		s ~= "\n" ~ m_main.info();
		s ~= "\n-Installed modules:";
		foreach(string k, p; m_packages)
			s ~= "\n" ~ p.info();
		return s;
	}
	
	/// Writes the application's metadata to the package.json file
	/// in it's root folder.
	void writeMetadata() const {
		assert(false);
		// TODO
	}
	
	/// Rereads the applications state.
	void reinit() {
		m_packages.clear();
		m_main = null;
		
		if(!exists(to!string(m_root~"package.json"))) {
			logWarn("There was no 'package.json' found for the application in '%s'.", m_root);
		}
		else {
			m_main = new Package(m_root);
			if(exists(to!string(m_root~"modules"))) {
				foreach( string pkg; dirEntries(to!string(m_root ~ "modules"), SpanMode.shallow) ) {
					if( !isDir(pkg) ) continue;
					try {
						auto p = new Package( Path(pkg) );
						enforce( p.name !in m_packages, "Duplicate package: " ~ p.name );
						m_packages[p.name] = p;
					}
					catch(Throwable e) {
						logWarn("The module '%s' in '%s' was not identified as a vibe package.", Path(pkg).head, pkg);
						continue;
					}
				}
			}
		}
	}
	
	/// Include paths for all installed modules
	string[] includePaths(bool views) const {
		// Assumeed that there is a \source folder
		string[] includes;
		string ipath() { return (views?"views":"source"); }
		foreach(string s, pkg; m_packages) {
			auto path = "modules/"~pkg.name~"/"~ipath();
			if( exists(path) && path.isDir )
				includes ~= path;
		}
		if( exists(ipath()) && ipath().isDir )
			includes ~= ipath(); // app sources/templates
		return includes;
	}
	
	/// Actions which can be performed to update the application.
	Action[] actions(PackageSupplier packageSupplier) const {
		if(!m_main) {
			Action[] a;
			return a;
		}
		
		auto graph = new DependencyGraph(m_main);
		RequestedDependency[string] missing = graph.missing();
		RequestedDependency[string] oldMissing;
		bool gatherFailed = false;
		while( missing.length > 0 ) {
			if(missing.length == oldMissing.length) {
				bool different = false;
				foreach(string pkg, reqDep; missing) {
					auto o = pkg in oldMissing;
					if(o && reqDep.dependency != o.dependency) {
						different = true; break;
					}
				}
				if(!different) {
					logWarn("Could not resolve dependencies");
					gatherFailed = true;
					break;
				}
			}
			
			oldMissing = missing.dup;
			logTrace("There are %s packages missing.", missing.length);
			foreach(string pkg, reqDep; missing) {
				if(!reqDep.dependency.valid()) {
					logTrace("Dependency to "~pkg~" is invalid. Trying to fix by modifying others.");
					continue;
				}
				
				logTrace("Adding package to graph: "~pkg);
				try {
					graph.insert(new Package(packageSupplier.packageJson(pkg, reqDep.dependency)));
				}
				catch(Throwable e) {
					// catch?
					logError("Trying to get package metadata failed, exception: %s", e.toString());
				}
			}
			graph.clearUnused();
			missing = graph.missing();
		}
		
		if(gatherFailed) {
			logError("The dependency graph could not be filled.");
			Action[] actions;
			foreach( string pkg, rdp; missing)
				actions ~= Action(Action.ActionId.Failure, pkg, rdp.dependency, rdp.packages);
			return actions;
		}
		
		auto conflicts = graph.conflicted();
		if(conflicts.length > 0) {
			logDebug("Conflicts found");
			Action[] actions;
			foreach( string pkg, dbp; conflicts)
				actions ~= Action(Action.ActionId.Conflict, pkg, dbp.dependency, dbp.packages);
			return actions;
		}
		
		// Gather installed
		Rebindable!(const Package)[string] installed;
		installed[m_main.name] = m_main;
		foreach(string pkg, ref const Package p; m_packages) {
			enforce( pkg !in installed, "The package '"~pkg~"' is installed more than once." );
			installed[pkg] = p;
		}
		
		// To see, which could be uninstalled
		Rebindable!(const Package)[string] unused = installed.dup;
		unused.remove( m_main.name );
	
		// Check against installed and add install actions
		Action[] actions;
		foreach( string pkg, d; graph.needed() ) {
			auto p = pkg in installed;
			// TODO: auto update to latest head revision
			if(!p || !d.dependency.matches(p.vers)) {
				if(!p) logDebug("Application not complete, required package '"~pkg~"', which was not found.");
				else logDebug("Application not complete, required package '"~pkg~"', invalid version. Required '%s', available '%s'.", d.dependency, p.vers);
				actions ~= Action(Action.ActionId.InstallUpdate, pkg, d.dependency, d.packages);
			} else {
				logDebug("Required package '"~pkg~"' found with version '"~p.vers~"'");
				if( (pkg in unused) !is null )
					unused.remove(pkg);
			}
		}
		
		// Add uninstall actions
		Action[] uninstalls;
		foreach( string pkg, p; unused ) {
			logDebug("Superfluous package found: '"~pkg~"', version '"~p.vers~"'");
			Dependency[string] em;
			uninstalls ~= Action( Action.ActionId.Uninstall, pkg, new Dependency("==" ~ p.vers), em);
		}
		
		// Ugly "uninstall" comes first
		actions = uninstalls ~ actions;
		
		return actions;
	}
	
	void createZip(string destination) {
		assert(false); // not properly implemented
		/*
		string[] ignores;
		auto ignoreFile = to!string(m_root~"vpm.ignore.txt");
		if(exists(ignoreFile)){
			auto iFile = openFile(ignoreFile);
			scope(exit) iFile.close();
			while(!iFile.empty) 
				ignores ~= to!string(cast(char[])iFile.readLine());
			logDebug("Using '%s' found by the application.", ignoreFile);
		}
		else {
			ignores ~= ".svn/*";
			ignores ~= ".git/*";
			ignores ~= ".hg/*";
			logDebug("The '%s' file was not found, defaulting to ignore:", ignoreFile);
		}
		ignores ~= "modules/*"; // modules will not be included
		foreach(string i; ignores)
			logDebug(" " ~ i);
		
		logDebug("Creating zip file from application: " ~ m_main.name);
		auto archive = new ZipArchive();
		foreach( string file; dirEntries(to!string(m_root), SpanMode.depth) ) {
			enforce( Path(file).startsWith(m_root) );
			auto p = Path(file);
			p = p[m_root.length..p.length];
			if(isDir(file)) continue;
			foreach(string ignore; ignores) 
				if(globMatch(file, ignore))
					would work, as I see it;
					continue;
			logDebug(" Adding member: %s", p);
			ArchiveMember am = new ArchiveMember();
			am.name = to!string(p);
			auto f = openFile(file);
			scope(exit) f.close();
			am.expandedData = f.readAll();
			archive.addMember(am);
		}
		
		logDebug(" Writing zip: %s", destination);
		auto dst = openFile(destination, FileMode.CreateTrunc);
		scope(exit) dst.close();
		dst.write(cast(ubyte[])archive.build());
		*/
	}
}

/// The default supplier for packages, which is the registry
/// hosted by vibed.org.
PackageSupplier defaultPackageSupplier() {
	Url url = Url.parse("http://127.0.0.1:8080/registry/");
	return new RegistryPS(url);
}

/// The Vpm or Vibe Package Manager helps in getting the applications
/// dependencies up and running.
class Vpm {
	private {
		Path m_root;
		Application m_app;
		PackageSupplier m_packageSupplier;
	}
	
	/// Initiales the package manager for the vibe application
	/// under root. 
	this(Path root, PackageSupplier ps = defaultPackageSupplier()) {
		enforce(root.absolute, "Specify an absolute path for the VPM");
		m_root = root;
		m_packageSupplier = ps;
		m_app = new Application(root);
	}
	
	/// Creates the deps.txt file, which is used by vibe to execute
	/// the application.
	void createDepsTxt() {
		string ipaths(bool t) { 
			string ret;
			foreach(s; m_app.includePaths(t)) {
				if(ret == "") ret = (t?"-J":"-I")~s;
				else ret ~= ";"~s;
			}
			return ret;
		}
		string source = ipaths(false);
		string views = ipaths(true);
		auto file = openFile("deps.txt", FileMode.CreateTrunc);
		scope(exit) file.close();
		string deps = source~"\n"~views;
		file.write(cast(ubyte[])deps);
	}
	
	/// Lists all installed modules
	void list() {
		logInfo(m_app.info());
	}
	
	/// Performs installation and uninstallation as necessary for
	/// the application.
	bool update(bool justAnnotate=false) {
		Action[] actions = m_app.actions(m_packageSupplier);
		if( actions.length == 0 ) {
			logInfo("You are up to date");
			return true;
		}
		
		logInfo("The following changes could be performed:");
		bool conflictedOrFailed = false;
		foreach(Action a; actions) {
			logInfo(capitalize( to!string( a.action ) ) ~ ": " ~ a.packageId ~ ", version %s", a.vers);
			if( a.action == Action.ActionId.Conflict || a.action == Action.ActionId.Failure ) {
				logInfo("Issued by: ");
				conflictedOrFailed = true;
				foreach(string pkg, d; a.issuer)
					logInfo(" "~pkg~": %s", d);
			}
		}
		
		if( conflictedOrFailed || justAnnotate )
			return conflictedOrFailed;
		
		// Uninstall first
		
		// ??
		// foreach(Action a	   ; filter!((Action a)        => a.action == Action.ActionId.Uninstall)(actions))
			// uninstall(a.packageId);
		// foreach(Action a; filter!((Action a) => a.action == Action.ActionId.InstallUpdate)(actions))
			// install(a.packageId, a.vers);
		foreach(Action a; actions)
			if(a.action == Action.ActionId.Uninstall)
				uninstall(a.packageId);
		foreach(Action a; actions)
			if(a.action == Action.ActionId.InstallUpdate)
				install(a.packageId, a.vers);
		
		m_app.reinit();
		Action[] newActions = m_app.actions(m_packageSupplier);
		if(newActions.length > 0) {
			logInfo("There are still some actions to perform:");
			foreach(Action a; newActions)
				logInfo("%s", a);
		}
		else
			logInfo("You are up to date");
		
		return newActions.length == 0;
	}
	
	/// Creates a zip from the application.
	void createZip(string zipFile) {
		m_app.createZip(zipFile);
	}
	
	/// Prints some information to the log.
	void info() {
		logInfo("Status for %s", m_root);
		logInfo("\n" ~ m_app.info());
	}

	/// Installs the package matching the dependency into the application.
	/// @param addToApplication if true, this will also add an entry in the
	/// list of dependencies in the application's package.json
	void install(string packageId, const Dependency dep, bool addToApplication = false) {
		logInfo("Installing "~packageId~"...");
		auto destination = m_root ~ "modules" ~ packageId;
		if(exists(to!string(destination)))
			throw new Exception(packageId~" needs to be uninstalled prior installation.");
		
		// download
		ZipArchive archive;
		{
			logDebug("Aquiring package zip file");
			auto dload = m_root ~ "temp/downloads";
			if(!exists(to!string(dload)))
				mkdirRecurse(to!string(dload));
			auto tempFile = m_root ~ ("temp/downloads/"~packageId~".zip");
			enforce(!exists(to!string(tempFile)), "Want to download package, but a file is occupying that space already: '"~to!string(tempFile)~"'");
			m_packageSupplier.storePackage(tempFile, packageId, dep); // Q: continue on fail?
			scope(exit) remove(to!string(tempFile));
			
			// unpack 
			auto f = openFile(to!string(tempFile), FileMode.Read);
			scope(exit) f.close();
			ubyte[] b = new ubyte[cast(uint)f.leastSize];
			f.read(b);
			archive = new ZipArchive(b);
		}
		
		Path getPrefix(ZipArchive a) {
			foreach(ArchiveMember am; a.directory)
				if( Path(am.name).head == PathEntry("package.json") )
					return Path(am.name).parentPath;
			
			// not correct zip packages HACK
			Path minPath;
			foreach(ArchiveMember am; a.directory)
				if( isPathFromZip(am.name) && (minPath == Path() || minPath.startsWith(Path(am.name))) )
					minPath = Path(am.name);
			
			return minPath;
		}
		
		logDebug("Installing from zip.");
		
		// In a github zip, the actual contents are in a subfolder
		auto prefixInPackage = getPrefix(archive);
		
		// install
		mkdirRecurse(to!string(destination));
		Journal journal = new Journal;
		foreach(ArchiveMember a; archive.directory) {
			auto path = Path(a.name);
			if(prefixInPackage != Path() && !path.startsWith(prefixInPackage)) continue;
			auto cleanedPath = path[prefixInPackage.length..path.length];
			if(cleanedPath.empty) continue;
			
			auto fileName = destination~cleanedPath;
			if(isPathFromZip(a.name)) {
				mkdirRecurse(to!string(to!string(fileName)));
				auto subPath = cleanedPath;
				for(size_t i=0; i<subPath.length; ++i)
					journal.add(Journal.Entry(Journal.Type.Directory, subPath[0..i+1]));
			}
			else {
				enforce(exists(to!string(fileName.parentPath)));
				auto dstFile = openFile(to!string(fileName), FileMode.CreateTrunc);
				scope(exit) dstFile.close();
				dstFile.write(archive.expand(a));
				journal.add(Journal.Entry(Journal.Type.RegularFile, cleanedPath));
			}
		}
		
		// Write journal
		journal.add(Journal.Entry(Journal.Type.RegularFile, Path("journal.json")));
		journal.save(destination ~ "journal.json");
		
		logInfo(packageId ~ " has been installed with version %s", (new Package(destination)).vers);
	}
	
	/// Uninstalls a given package from the list of installed modules.
	/// @removeFromApplication: if true, this will also remove an entry in the
	/// list of dependencies in the application's package.json
	void uninstall(const string packageId, bool removeFromApplication = false) {
		logInfo("Uninstalling " ~ packageId);
		
		auto journalFile = m_root~"modules"~packageId~"journal.json";
		if( !exists(to!string(journalFile)) )
			throw new Exception("Uninstall failed, no journal found for '"~packageId~"'. Please uninstall manually.");
	
		auto packagePath = m_root~"modules"~packageId;
		auto journal = new Journal(journalFile);
		logDebug("Erasing files");
		foreach( Journal.Entry e; filter!((Journal.Entry a) => a.type == Journal.Type.RegularFile)(journal.entries)) {
			logTrace("Deleting file '%s'", e.relFilename);
			auto absFile = packagePath~e.relFilename;
			if(!exists(to!string(absFile))) {
				logWarn("Previously installed file not found for uninstalling: '%s'", absFile);
				continue;
			}
			
			remove(to!string(absFile));
		}
		
		logDebug("Erasing directories");
		Path[] allPaths;
		foreach(Journal.Entry e; filter!((Journal.Entry a) => a.type == Journal.Type.Directory)(journal.entries))
			allPaths ~= packagePath~e.relFilename;
		sort!("a.length>b.length")(allPaths); // sort to erase deepest paths first
		foreach(Path p; allPaths) {
			logTrace("Deleting folder '%s'", p);
			if( !exists(to!string(p)) || !isDir(to!string(p)) || !isEmptyDir(p) ) {
				logError("Alien files found, directory is not empty or is not a directory: '%s'", p);
				continue;
			}
			rmdir( to!string(p) );
		}
		
		if(!isEmptyDir(packagePath))
			throw new Exception("Alien files found in '"~to!string(packagePath)~"', manual uninstallation needed.");
		
		rmdir(to!string(packagePath));
		logInfo("Uninstalled package: '"~packageId~"'");
	}
}