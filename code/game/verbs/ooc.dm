
/client/verb/ooc(msg as text)
	set name = "OOC"
	set category = "OOC"

	if(say_disabled)	//This is here to try to identify lag problems
		usr << "\red Speech is currently admin-disabled."
		return

	if(!mob)	return
	if(IsGuestKey(key))
		src << "Guests may not use OOC."
		return

	msg = sanitize(msg)
	if(!msg)	return

	if(!(prefs.toggles & CHAT_OOC))
		src << "\red You have OOC muted."
		return

	if(!holder)
		if(!config.ooc_allowed)
			src << "<span class='danger'>OOC is globally muted.</span>"
			return
		if(!config.dooc_allowed && (mob.stat == DEAD))
			usr << "<span class='danger'>OOC for dead mobs has been turned off.</span>"
			return
		if(prefs.muted & MUTE_OOC)
			src << "<span class='danger'>You cannot use OOC (muted).</span>"
			return
		if(handle_spam_prevention(msg,MUTE_OOC))
			return
		if(findtext(msg, "byond://"))
			src << "<B>Advertising other servers is not allowed.</B>"
			log_admin("[key_name(src)] has attempted to advertise in OOC: [msg]")
			message_admins("[key_name_admin(src)] has attempted to advertise in OOC: [msg]")
			return

	var/ooc_style = "everyone"
	if(holder && !holder.fakekey)
		ooc_style = "elevated"
		if(holder.rights & R_MOD)
			ooc_style = "moderator"
		if(holder.rights & R_DEBUG)
			ooc_style = "developer"
		if(holder.rights & R_ADMIN)
			ooc_style = "admin"

	log_ooc("[mob.name]/[key] : [msg]")
	STUI.ooc.Add("\[[time_stamp()]] <font color='#0066FF'>OOC: [mob.name]/[key]: [msg]</font><br>")
	STUI.processing |= 4

	for(var/client/target in clients)
		if(target.prefs.toggles & CHAT_OOC)
			var/display_name = src.key

			if( target.prefs.toggles & SOUND_NOTIFICATIONS )
				target << sound( 'sound/effects/oocalert.ogg' )

			if(holder)
				if(holder.fakekey)
					if(target.holder)
						display_name = "[holder.fakekey]/([src.key])"
					else
						display_name = holder.fakekey
			if(src.IsByondMember())
				target << "<font color='[src.prefs.ooccolor]'><span class='ooc'>" + create_text_tag("byond-ooc", "VIP-OOC:", target) + " <EM>[display_name]:</EM> <span class='message'>[msg]</span></span></font>"
			else if(holder && !holder.fakekey && (holder.rights & R_ADMIN) && config.allow_admin_ooccolor && (src.prefs.ooccolor != initial(src.prefs.ooccolor))) // keeping this for the badmins
				target << "<font color='[src.prefs.ooccolor]'><span class='ooc'>" + create_text_tag("ooc", "OOC:", target) + " <EM>[display_name]:</EM> <span class='message'>[msg]</span></span></font>"
			else if(donator_tier(src) == 2)
				target << "<font color='[src.prefs.ooccolor]'><span class='ooc'>" + create_text_tag("ooc", "OOC:", target) + " <EM>[display_name]:</EM> <span class='message'>[msg]</span></span></font>"
			else if(donator_tier(src) == 1)
				target << "<span class='ooc'><span class='donator'>" + create_text_tag("ooc", "OOC:", target) + " <EM>[display_name]:</EM> <span class='message'>[msg]</span></span></span></font>"
			else if(get_title(src) == 2)
				target << "<span class='ooc'><span class='spriter'>" + create_text_tag("ooc", "OOC:", target) + " <EM>[display_name]:</EM> <span class='message'>[msg]</span></span></span></font>"	//for founded, don't have a colour for event team yet.
			else
				target << "<span class='ooc'><span class='[ooc_style]'>" + create_text_tag("ooc", "OOC:", target) + " <EM>[display_name]:</EM> <span class='message'>[msg]</span></span></span>"

/client/verb/looc(msg as text)
	set name = "LOOC"
	set desc = "Local OOC, seen only by those in view."
	set category = "OOC"

	if(say_disabled)	//This is here to try to identify lag problems
		usr << "\red Speech is currently admin-disabled."
		return

	if(!mob)	return
	if(IsGuestKey(key))
		src << "Guests may not use OOC."
		return

	msg = sanitize(msg)
	if(!msg)	return

	if(!(prefs.toggles & CHAT_LOOC))
		src << "\red You have LOOC muted."
		return

	if(!holder)
		if(!config.ooc_allowed)
			src << "<span class='danger'>OOC is globally muted.</span>"
			return
		if(!config.dooc_allowed && (mob.stat == DEAD))
			usr << "<span class='danger'>OOC for dead mobs has been turned off.</span>"
			return
		if(prefs.muted & MUTE_OOC)
			src << "<span class='danger'>You cannot use OOC (muted).</span>"
			return
		if(handle_spam_prevention(msg,MUTE_OOC))
			return
		if(findtext(msg, "byond://"))
			src << "<B>Advertising other servers is not allowed.</B>"
			log_admin("[key_name(src)] has attempted to advertise in OOC: [msg]")
			message_admins("[key_name_admin(src)] has attempted to advertise in OOC: [msg]")
			return

	log_ooc("(LOCAL) [mob.name]/[key] : [msg]")

	var/mob/source = src.mob
	var/list/heard = get_mobs_in_view(7, source)

	var/display_name = source.key
	if(holder && holder.fakekey)
		display_name = holder.fakekey
	if(source.stat != DEAD)
		display_name = source.name

	var/prefix
	var/admin_stuff

	for(var/client/target in clients)
		if(target.prefs.toggles & CHAT_LOOC)
			admin_stuff = ""
			if(target in admins)
				prefix = "(R)"
				admin_stuff += "/([source.key])"
				if(target != source.client)
					admin_stuff += "(<A HREF='?src=\ref[target.holder];adminplayerobservejump=\ref[mob]'>JMP</A>)"
			if(target.mob in heard)
				prefix = ""
			if((target.mob in heard) || (target in admins))
				if(source.client.IsByondMember())
					target << "<span class='ooc'><span class='looc'>" + create_text_tag("byond-looc", "VIP-LOOC:", target) + " <span class='prefix'>[prefix]</span><EM>[display_name][admin_stuff]:</EM> <span class='message'>[msg]</span></span></span>"
				else
					target << "<span class='ooc'><span class='looc'>" + create_text_tag("looc", "LOOC:", target) + " <span class='prefix'>[prefix]</span><EM>[display_name][admin_stuff]:</EM> <span class='message'>[msg]</span></span></span>"

	STUI.ooc.Add("\[[time_stamp()]] <font color='#3A9696'>LOOC: [mob.name]/[key]: [msg]</font><br>")
	STUI.processing |= 4