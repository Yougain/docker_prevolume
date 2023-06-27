

require 'yaml'


require 'Yk/debug2'

class String
	require 'pathname'
	def / arg
		if self == "" || arg == ""
			raise "cannot concatenate path elems, #{self.inspect} && #{arg.inspect}"
		elsif arg[0] == "/"
			raise "cannot concatenate absolute path, #{arg.inspect} on #{self.inspect}"
		else
			Pathname.new(self + "/" + arg).cleanpath(true).to_s
		end
	end
	def setRegexpr reg
		@regexp = reg
	end
	def glob
		# check exist for overlay system
		# cannot use "/" : symbolic link is misiterpreted when chroot case
		ret = Dir.glob(self)
		if @regexp
			ret.delete_if{_1 !~ @regexp}
		end
		ret.delete_if{!_1.lexist?}
		ret
	end
	def cleanpath
		s = Pathname.new(self).cleanpath(true).to_s
		case s
		when "."
			s = "./"
		when ".."
			s = "../"
		when /\/\.$/
			s = $` + "/"
		when /\/\.\.$/
			s = $` + "../"
		end
		replace(s)
		self
	end
	def unchroot root
		if root == "" || self == ""
			raise "cannot unroot #{self.inspect} to #{root.inspect}"
		else
			if self == "/"
				return root
			elsif self[0] == "/"
				if root == "/"
					return self
				else
					return root / self[1..-1]
				end
			else
				root / self
			end
		end
	end
	def path_elems
		if self == ""
			raise "cannot split #{self.inspect} to path elements"
		else
			cleanpath
			ret = split "/", -1
			(ret.size - 1).times do |i|
				ret[i] += "/"
			end
			if ret[-1] == ""
				ret.pop
			end
			ret
		end
	end
	def each_dir
		y = ""
		path_elems[0..-2].each do |e|
			yield (y += e).clone
		end
	end
	def dirname
		File.dirname(self)
	end
	def basename
		File.basename(self)
	end
	def dname
		ret = File.dirname(self)
		if ret != "/"
			ret + "/"
		else
			ret
		end
	end
	def bname
		File.basename(self) + (self != "/" && self[-1] == "/" ? "/" : "")
	end
	def dir_n_base
		[dname, bname]
	end
	def symlink?
		File.symlink?(self) && File.readlink(self) != "(overlay-whiteout)"
	end
	def directory?
		File.directory?(self)
	end
	def readlink
		File.readlink(self)
	end
	def children
		Dir.children(self).delete_if{!(self / _1).lexist?}
	end
	def deleted?
		((File.chardev?(self) || File.blockdev?(self)) && File.stat(self).rdev == 0) ||
		(File.symlink?(self) && File.readlink(self) == "(overlay-whiteout)")
	end
	def rmdir
		Dir.rmdir(self)
	end
	def exist?
		if File.exist?(self)
			if (File.chardev?(self) || File.blockdev?(self)) && File.stat(self).rdev == 0
				false
			elsif File.symlink?(self) && File.readlink == "(overlay-whiteout)"
				false
			else
				true
			end
		else
			false
		end
	end
	def lstat
		File.lstat(self)
	end
	def stat
		File.stat(self)
	end
	def lexist?
		if !symlink?
			if !File.exist?(self)
				false
			elsif (File.chardev?(self) || File.blockdev?(self)) && File.stat(self).rdev == 0
				false
			else
				true
			end
		elsif readlink == "(overlay-whiteout)"
			false
		else # symlink
			true
		end
	end
	def ldirectory?
		!symlink? && directory?
	end
	def relative?
		self[0] != "/"
	end
	def absolute?
		self[0] == "/"
	end
	def home?
		self[0] == "~"
	end
	def lino
		s = File.lstat(self)
		[s.dev, s.ino]
	end
	def relative_path_from f
		Pathname.new(self).relative_path_from(f).to_s
	end
	def rm
		FileUtils.rm self
	end
end


class ChrootFS
	def initialize data = nil
		@roots = [data] if data
	end
	def pushOverlayLayer *l
		(@roots ||= []).push *l
	end
	def roots
		if !@roots || @roots.empty?
			["/"]
		else
			@roots
		end
	end
	def resolv ef, symlinks = nil
		ef = ef.cleanpath
		if ef != "/"
			case ef[0]
			when "/"
				_resolv "/", ef[1..-1], symlinks
			when /^\~/
				if $' == ""
					user = ENV['USER']
					if !user
						raise("Environmental variable 'USER' is not set")
					end
				else
					user = ef.dirname[1..-1]
				end
				home = nil
				IO.foreach getFile("/etc/passwd") do |ln|
					u, h = ln.split.value_at(0, 5)
					if u == user
						home = h
						break
					end
				end
				if !home || home.empty?
					raise "cannot detect home directory of #{user}"
				end
				resolv home / ef.bname, symlinks
			else
				raise "cannot handle relative path, '#{ef}'\n"
			end
		else
			["/"]
		end
	end
	private
	def _resolv resolved, ef, symlinks, lkList = nil
		leftList = nil
		if ef[0] == "/"
			raise "cannot handle absolute path, '#{ef}'\n"
		end
		pElems = ef.path_elems # usr/**/bin/ls -> ["usr/", "**/", "bin/", "ls" ]
		leftList = Set.new.add resolved
		while !pElems.empty?
			elem = pElems.shift
			newList = Set.new
			leftList.each do |left|
				newList.merge resolvBase(left / elem, symlinks, lkList)
			end
			return newList if newList.empty?
			leftList = newList
		end
		leftList
	end
		
	def getGlobs pth
		gset = Set.new
		roots.reverse_each do |r|
			rpth = pth.unchroot r
			rpth.glob.map{gset.add _1.bname}
		end
		gset.to_a.map{pth.dname / _1}
	end
	
	def findRootOf pth
		roots.reverse_each do |r|
			isDir = false
			rpth = pth.unchroot r
			if pth =~ /subuid\-/
				#p [r, rpth, rpth.deleted?]
				#system "ls -la #{rpth}"
			end
			if rpth.deleted?
				break
			elsif rpth.ldirectory?
				yield r
				isDir = true
			elsif rpth.lexist?
				!isDir and yield(r)
				break
			end
		end
	end
	
	def findChildOf pth
		rset = {}
		findRootOf pth do |r|
			rp = pth.unchroot r
			rp.children.each do |c|
				rset[c] ||= [rp / c, pth / c]
			end
		end
		rset.each_value do |k, krel|
			if !k.deleted?
				yield k, krel
			end
		end
	end
	
	def resolvBase ef, symlinks, lkList = nil
		require 'set'
		resList = Set.new
		dn, bn = ef.dir_n_base

		tryFollowSymLink = -> e, erel, linos = [] {
			ret = Set.new
			if e.symlink? && !linos.include?(e.lino)
				symlinks&.add [e, erel]
				lkr = e.readlink.cleanpath
				if lkr.absolute?
					pre_resolved = "/"
					lkr = lkr[1..-1]
				elsif lkr.home?
					ret.merge resolve(lkr, symlinks)
				else
					pre_resolved = erel.dname
				end
				if pre_resolved
					_resolv(pre_resolved, lkr, symlinks)&.each do |nest|
						findRootOf nest do |r|
							if !tryFollowSymLink[r.unchroot(nest), nest, linos.clone.push(e.lino)]&.tap{ret += _1}
								ret.add nest
							end
						end
					end
				end
				ret
			else
				nil
			end
		}

		case bn
		when "../", ".."
			resList.add dn.dname
		when  "**/"
			findChildOf dn do |k, krel|
				if k.ldirectory? # non-symlink directory
					resolvBase(krel / "**/", symlinks, lkList).each do |resolved|
						resList.add resolved
					end
				else
					fdList = Set.new
					followList = tryFollowSymLink[k, krel] # recursively resolve symlink
					if followList 
						if !lkList&.include?(k.lino) # remove recursive referrence
							followList.each do |follow|
								findRootOf follow do |r|
									if (follow.unchroot r).directory?
										resolvBase(follow / "**/", symlinks, (lkList&.clone || []).push(k.lino)).each do |reresolved|
											resList.add reresolved
										end
									end
									break
								end
							end
						end
					else
						resList.add krel
					end
				end
			end
			#resList.add dn
		else
			fndR = ->eg{
				findRootOf eg do |r|
					pth = eg.unchroot r
					if linkResolved = tryFollowSymLink[pth, eg]
						linkResolved.each do |resolved|
							resList.add resolved
						end
					else
						resList.add eg
					end
				end
			}
			if bn =~ /\[|\{|\?|\*/
				getGlobs(ef).each do |eg|
					fndR[eg]
				end
			else
				fndR[ef]
			end
		end
		resList
	end
	public
	def getSrcDst t
		symlinks = Set.new
		pths = resolv(t, symlinks)
		ret = Set.new
		pths.each do |e|
			findRootOf e do |r|
				ret.add [e.unchroot(r), e]
				break
			end
		end
		ret.merge symlinks
		ret
	end
	def isDir t
		
	end
end


def takeFirst arr
	set = {}
	ret = []
	arr.each do |e|
		if !set.key? e
			set[e] = true
			ret.push e
		end
	end
	ret
end


TMP_OV = "/var/lib/docker/tmp/docker_ov/"
TMP_OVW = "#{TMP_OV}#{$$}.work"
TMP_OVM = "#{TMP_OV}#{$$}.merged"


class Mount
	Y = YAML.load(IO.read "./docker-compose.yml") rescue die("cannot open './docker-compose.yml'")

	svs = Y["services"]
	if svs.keys.size != 1
		die "Error: Sorry. Multiple services are not supported (#{svs.keys.join(', ')} are defined in ./docker-compose.yml)."
	end

	sv = svs.keys[0]
	SV = svs[sv]
	CurDirTag = File.basename(Dir.pwd)
	BaseImage = "#{CurDirTag}-#{sv}"
	imNames = []
	`docker ps`.each_line do |ln|
		lns = ln.split
		if lns[1] == BaseImage
			imNames.push lns[-1]
		end
	end
	if imNames.empty?
		imNames.push BaseImage
		print "Warning: using base image, #{BaseImage}.\n"
	elsif imNames.size > 1
		die "Error: multiple images, #{imNames.join(', ')} are executing."
	end
	ImageName = imNames[0]
	insp = `docker inspect #{ImageName}`.gsub(/null/, "nil")
	Insp = eval insp
	Data =Insp[0][:GraphDriver][:Data]
	Ovl = ChrootFS.new
	Ovl.pushOverlayLayer *Data[:LowerDir].split(/:/).reverse
	Ovl.pushOverlayLayer Data[:UpperDir]
	ToWrite = if !Data[:MergedDir].directory?
		[TMP_OVM, TMP_OVW].each{ FileUtils.mkpath _1 }
		cmd = %W{mount -t overlay overlay -o lowerdir=#{Data[:LowerDir]},upperdir=#{Data[:UpperDir]},workdir=#{TMP_OVW} #{TMP_OVM}}
		print cmd.join(' ') + "\n"
		if !system *cmd
			raise "cannot mount overlay: #{TMP_OVW}"
		end
		at_exit {
			`cat /proc/self/mountinfo`.each_line do |ln|
				if (um = ln.split[4]) =~ /^#{Regexp.escape TMP_OV}/
					if system *%W{umount #{um}}
						[um, um.sub(/.merged$/, ".work")].each do
							FileUtils.rm_rf _1
						end
					end
				end
			end
			TMP_OV.children.each do |d|
				d = TMP_OV / d
				if d.directory?
					begin
						if (dw = d / "work").directory?
							Dir.rmdir dw
						end
						Dir.rmdir d
					rescue Errno::ENOTEMPTY
						print "Warning: cannot remove directory, #{d}\n"
					end
				end
			end
		}
		[Data[:UpperDir]].detect{_1.directory?} or die "Upperdir: #{Data[:UpperDir]}, not found."
	else
		Data[:MergedDir]
	end
	Merged = [TMP_OVM, Data[:MergedDir]].detect{_1.directory?}
	um_saidai = 1000
	Dir.glob("/home/data/*/etc/login.defs").each do |f|
		if IO.read(f) =~ /^UID_MIN\s+(\d+)/
			if um_saidai < (um = $1.to_i)
				um_saidai = um
			end
		end
	end
	um_saidai += 1000
	UM_SAIDAI = um_saidai


	class Elem
	 	def initialize n, par
	 		@name = n
	 		@parent = par
	 		@children = {}
	 	end
	 	def setSource s
	 		@source = s
	 	end
	 	def emergeChild ent
	 		@children[ent] ||= Elem.new(ent, self)
	 	end
	 	def clearChildren
	 		@children.clear
	 	end
	 	def getChild ent
	 		@children[ent]
	 	end
	 	def getPath d, f
	 		if @source
	 			@source / (d.empty? ? "" : d) / f
	 		else
	 			@parent ? @parent.getPath(@name / d, f) : nil
	 		end
	 	end
	 	attr_reader :source
	end
	Root = Elem.new("", nil)
	def self.[]= t, s # Mount["/etc/samba"] = "/home/data/samba/etc/samba"
		parr = t.split "/"
		if parr[0] != ""
			raise "'#{t}' is not an absolute path."
		end
		if s[0] == "/"
			c = Root
			parr.each do |ent|
				c = c.emergeChild(ent)
			end
			c.clearChildren
			c.setSource(s)
		else
			raise "Source path, '#{s}' is not absolute"
		end
	end
	def self.getPathFor pth
		parr = pth.split "/"
		if parr[0] != ""
			raise "'#{t}' is not an absolute path."
		end
		c = Root
		parr.shift
		if parr[0..-2].detect{_1 =~ /\*|\[|\{/}
			raise "cannot use glob expression in directory."
		end
		parr.each_with_index do |ent, i|
			c2 = c.getChild(ent)
			if !c2
				r = c.getPath(parr[i..-2].join('/'), parr[-1])
				return r
			else
				c = c2
			end
		end
		raise "getPath trouble."
	end
	def self.getSrcDst t, sds # path of existing file
		if t =~ /^\/(proc|dev|sys)\//
			r = t.glob
			if r
				sds.add [r, r] # is from proc or sys, dev filesystem
			end
		else
			pth = getPathFor t
			if pth
				sds.add [pth, t] # glob or regexp match
			else # nil ; not exist in volumes
				sds.merge Ovl.getSrcDst(t)
			end
		end
	end
	def self.isDir t
		if t =~ /^\/(proc|dev|sys)\//
			t.ldirectory?
		elsif pth = getPathFor(t)
			pth.ldirectory?
		else
			Ovl.isDir t
		end
	end
	def self.getOneFor t
		res = getSrcDst(t, Set.new)
		if res.empty?
			nil
		else
			res.to_a[0][0]
		end
	end
	def self.unretrieve ef, tmp_root
		(eft = ef.unchroot ToWrite).tap {
			if _1.ldirectory?
				raise "cannot unretrieve directory."
			end
		}
		if false # do not use merged root
			t = ef
			s = Set.new
			while true
				getSrcDst(t, s)
				break if !s.empty?
				t = t.dname
			end
			s = s.to_a
			target = nil
			if ef != t
				if s.size == 1
					target = s[0][0]
					t.relative_path_from(s[0][1]).each_dir do |d|
						target = s[0][0] / d
						origin = tmp_root / s[0][1] / d
						Dir.mkdir target
						st = File.stat origin
						File.chmod st.mode, target
						File.chown st.uid, st.gid, target
						File.utime st.atime, st.mtime, target
					end
				else
					raise "cannot unretrieve symblic link."
				end
			else
				target = s[0][0].dname
			end
			if (tt = target / eft.basename).deleted?
				print "Warning: cannot copy #{eft}\n"
			else
				FileUtils.copy eft, target, preserve: true
			end
		else # using merged root or upper root
			checkDir = Proc.new do |t|
				while true
					tef = t.unchroot ToWrite
					if tef.directory?
						break
					elsif tef.lexist?
						tef.rm
					end
					if t == "/"
						raise "#{ToWrite} does not exist"
					end
					checkDir[t.dname]
					Dir.mkdir tef
					st = File.stat(t.unchroot tmp_root)
					File.chmod st.mode, tef
					File.chown st.uid, st.gid, tef
					File.utime st.atime, st.mtime, tef
					break
				end
			end
			tef = ef.unchroot ToWrite
			if !tef.deleted?
				if !tef.exist?
					checkDir[ef.dname]
				end
				begin
					FileUtils.copy ef.unchroot(tmp_root), tef, preserve: true
				rescue Errno::ESTALE
					false
				else
					true
				end
			end or print("Warning: cannot copy #{tef}\n")
		end
	end
	def self.mkpath pth, src
		if !File.exist? pth
			mkpath File.dirname(pth), File.dirname(src)
			Dir.mkdir pth
			st = File.stat src
			File.utime(File.atime(src), File.mtime(src), pth)
			File.chmod(st.mode, pth)
			File.chown(st.uid, st.gid, pth)
			#system "echo -n src:; ls -lad #{src}"
			#system "echo -n pth:; ls -lad #{pth}"
		end
	end

	LdPath = []

	def self.getLdPath f, _dst
		IO.foreach f.unchroot _dst  do |ln|
			ln = ln.strip.sub /#.*/, ""
			if !ln.empty?
				arr = ln.split
				if arr[0] == "include"
					arr.shift
					arr.each do |e|
						if e.relative?
							e = f.dirname / e
						end
						retrieve [e], _dst
						(e.unchroot _dst).glob&.each do |ent|
							ent = ent.relative_path_from(_dst)
							getLdPath ent, _dst
						end
					end
				else
					arr.each do |e|
						if e.absolute?
							LdPath.push e
						end
					end
				end
			end
		end
	end

	def self.retrieveMayDescend ef, _dst, sds
		
	end

	def self.retrieve efs, _dst, recursive: false
		sds = Set.new
		recGlobs = []
		efs.each do |ef|
			ef = ef.cleanpath
			case ef
			when /(\A|\/)([^\/]+?)(\-\d+(\.\d+)*|)\.so(\.\d+)*\Z/ # lib file
				libName = $2
				origPath = $`
				if LdPath.empty?
					retrieve ["/etc/ld.so.conf"], _dst
					getLdPath "/etc/ld.so.conf", _dst
					LdPath.push *%W{
						/usr/local/lib
						/usr/local/lib64
						/usr/local/libx32
						/lib
						/lib64
						/libx32
						/usr/lib
						/usr/lib64
						/usr/libx32
					}
				end
				case origPath
				when /^\//
					if LdPath.include? origPath
						searchPath = [origPath] + LdPath
					else
						searchPath = [origPath]
					end
					middlePath = ""
				when "" # without directory
					searchPath = LdPath
					middlePath = ""
				else    # with relarive path
					searchPath = LdPath
					middlePath = "#{origPath}"
				end
				takeFirst(searchPath).each do |lp|
					%W{
						.so
						.so.*
						-*.so
						-*.so.*
					}.each do |last|
						if middlePath.empty?
							e = lp / libName + last
						else
							e = lp / middlePath / libName + last
						end
						getSrcDst e, sds
					end
				end
			when /\Abin\//
				%W{/bin /usr/bin /usr/local/bin}.each do |bp|
					getSrcDst bp /  $', sds
				end
			when /\Asbin\//
				%W{/sbin /usr/sbin /usr/local/sbin}.each do |bp|
					getSrcDst bp /  $', sds
				end
			when /\A[^\/]/
				raise("'#{ef}' is not absolute path")
			else
				if ef.basename !~ /\*\*\//
					getSrcDst ef, sds
				else
					recGlobs.push ef
				end
			end
		end
		if recursive
			sds.to_a.each do |src, dst|
				if src.ldirectory?
					getSrcDst (dst + "/**/").cleanpath, sds
				end
			end
		end
		recGlobs.each do |ef|
			getSrcDst ef, sds
		end
		dset = Set.new.add "/"
		sds.each do |src, dst|
			d = dst.unchroot _dst
			dnl = []
			dn = dst.dname
			while !dset.include? dn
				dnl.push dn
				dn = dn.dname
			end
			dnl.reverse_each do |dn|
				s = Set.new
				getSrcDst dn, s
				if s.empty?
					die "unknown error for '#{dn}'"
				end
				_s, _d = s.to_a[0]
				__d = _d.unchroot _dst
				Dir.mkdir __d if !File.directory?(__d)
				st = File.stat _s
				File.chmod st.mode, __d
				File.chown st.uid, st.gid, __d
				File.utime st.atime, st.mtime, __d
				dset.add dn
			end
			if src.directory? # should not be symlink 'cause already link resolved
				Dir.mkdir d if !d.directory?
				st = File.stat src
				File.chmod st.mode, d
				File.chown st.uid, st.gid, d
				File.utime st.atime, st.mtime, d
			else
				if !system "cp -arn #{src} #{d}"
					die "cannnot copy '#{src}' '#{d}'"
				end
			end
			if dst == "/etc/login.defs"
				lns = IO.read(d = "/etc/login.defs".unchroot(_dst)).gsub /^([UG]ID_MIN\s+)\d+/, "\\1#{UM_SAIDAI}"
				IO.write(d, lns)
			end
		end
		
	end


	SV["volumes"] ||= [] 
	(vs = SV["volumes"]).each do |e|
		case e
		when String
			s, t = e.split(/:/).map(&:strip) # ex. "/home/data/samba/etc/samba:/etc/samba"
		when Hash
			if !(s = e["source"]) || !(t = e["target"])
				raise "prameter missing"
			end
		end
		if s[0] == "/"
			self[t] = s
		else
			if ext = Y["volumes"]&.[](s)&.[]("external")
				if ext.is_a?(Hash) && ext["name"]
					s = ext["name"]
				end
				vs = eval `docker volume inspect #{s}`.gsub(/null/, "nil")
				if !vs[0] || !vs[0][:Mountpoint]
					raise "cannot find mountpoint of volume, '#{s}'"
				end
				self[t] = vs[0][:Mountpoint]
			else
				if m = Insp[:Mounts]&.detect{_1[:Name] == s }
					if m[:Destination] == t
						self[t] = m[:Source]
						break :found
					else
						raise "Volume, '#{s}' has conflict target: '#{t}' != '#{m[:Destination]}'"
					end
				else
					raise "cannot find target for volume, '#{s}'"
				end
			end
		end
	end
	

	ctags = Hash.new{|h, k| h[k] = {}}
	SV["configs"]&.each_with_index do |cdef, i|
		ctags[cdef]["order"] = i
		if cdef.is_a? String
			ctags[cdef]["target"] = "/" + cdef
		else
			ctags[cdef["source"]["target"]] = cdef["target"]
		end
	end

	ctags.each_key do |ctag|
		ctags[ctag]["source"] = File.expand_path(Y["configs"][ctag]["file"])
	end

	ctags.values.sort_by{|v| v["order"]}.each do |v|
		if v["target"] && v["source"]
			self[v["target"]] = v["source"]
		end
	end

end



