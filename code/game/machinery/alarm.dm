////////////////////////////////////////
//CONTAINS: Air Alarms and Fire Alarms//
////////////////////////////////////////

#define AALARM_MODE_SCRUBBING	1
#define AALARM_MODE_REPLACEMENT	2 //like scrubbing, but faster.
#define AALARM_MODE_PANIC		3 //constantly sucks all air
#define AALARM_MODE_CYCLE		4 //sucks off all air, then refill and switches to scrubbing
#define AALARM_MODE_FILL		5 //emergency fill
#define AALARM_MODE_OFF			6 //Shuts it all down.

#define AALARM_SCREEN_MAIN		1
#define AALARM_SCREEN_VENT		2
#define AALARM_SCREEN_SCRUB		3
#define AALARM_SCREEN_MODE		4
#define AALARM_SCREEN_SENSORS	5

#define AALARM_REPORT_TIMEOUT 100

#define RCON_NO		1
#define RCON_AUTO	2
#define RCON_YES	3

#define MAX_TEMPERATURE 90
#define MIN_TEMPERATURE -40

//all air alarms in area are connected via magic
/area
	var/obj/machinery/alarm/master_air_alarm
	var/list/air_vent_names = list()
	var/list/air_scrub_names = list()
	var/list/air_vent_info = list()
	var/list/air_scrub_info = list()

/obj/machinery/alarm
	name = "alarm"
	icon = 'icons/obj/monitors.dmi'
	icon_state = "alarm0"
	anchored = 1
	use_power = 1
	idle_power_usage = 80
	active_power_usage = 1000 //For heating/cooling rooms. 1000 joules equates to about 1 degree every 2 seconds for a single tile of air.
	power_channel = ENVIRON
	req_one_access = list(access_atmospherics, access_engine_equip)
	var/alarm_id = null
	var/breach_detection = 1 // Whether to use automatic breach detection or not
	var/frequency = 1439
	//var/skipprocess = 0 //Experimenting
	var/alarm_frequency = 1437
	var/remote_control = 0
	var/rcon_setting = 2
	var/rcon_time = 0
	var/locked = 1
	var/wiresexposed = 0 // If it's been screwdrivered open.
	var/aidisabled = 0
	var/shorted = 0

	var/datum/wires/alarm/wires

	var/mode = AALARM_MODE_SCRUBBING
	var/screen = AALARM_SCREEN_MAIN
	var/area_uid
	var/area/alarm_area
	var/buildstage = 2 //2 is built, 1 is building, 0 is frame.

	var/target_temperature = T0C+20
	var/regulating_temperature = 0

	var/datum/radio_frequency/radio_connection

	var/list/TLV = list()

	var/danger_level = 0
	var/pressure_dangerlevel = 0
	var/oxygen_dangerlevel = 0
	var/co2_dangerlevel = 0
	var/phoron_dangerlevel = 0
	var/temperature_dangerlevel = 0
	var/other_dangerlevel = 0

	var/report_danger_level = 1

/obj/machinery/alarm/monitor
	report_danger_level = 0
	breach_detection = 0

/obj/machinery/alarm/server/New()
	..()
	req_access = list(access_rd, access_atmospherics, access_engine_equip)
	TLV["oxygen"] =			list(-1.0, -1.0,-1.0,-1.0) // Partial pressure, kpa
	TLV["carbon dioxide"] = list(-1.0, -1.0,   5,  10) // Partial pressure, kpa
	TLV["phoron"] =			list(-1.0, -1.0, 0.2, 0.5) // Partial pressure, kpa
	TLV["other"] =			list(-1.0, -1.0, 0.5, 1.0) // Partial pressure, kpa
	TLV["pressure"] =		list(0,ONE_ATMOSPHERE*0.10,ONE_ATMOSPHERE*1.40,ONE_ATMOSPHERE*1.60) /* kpa */
	TLV["temperature"] =	list(20, 40, 140, 160) // K
	target_temperature = 90

/obj/machinery/alarm/Destroy()
	if(wires)
		qdel(wires)
		wires = null
	..()

/obj/machinery/alarm/New(var/loc, var/dir, var/building = 0)
	..()

	if(building)
		if(loc)
			src.loc = loc

		if(dir)
			src.set_dir(dir)

		buildstage = 0
		wiresexposed = 1
		pixel_x = (dir & 3)? 0 : (dir == 4 ? -24 : 24)
		pixel_y = (dir & 3)? (dir ==1 ? -24 : 24) : 0
		update_icon()
		if(ticker && ticker.current_state == 3)//if the game is running
			src.initialize()
		return

	first_run()

/obj/machinery/alarm/Destroy()
	//If there's an active alarm, clear it after minute so that alarms don't keep going forver
	delayed_reset()
	..()

//needed to cancel the alarm after it is deleted
/obj/machinery/alarm/proc/delayed_reset()
	var/area/A = alarm_area
	src = null
	spawn(600)
		//It makes sense not to touch firelocks here. The alarm itself is gone, we have no idea what the atmos is like.
		A.atmosalert(0, set_firelocks=0)

/obj/machinery/alarm/proc/first_run()
	alarm_area = get_area(src)

	area_uid = alarm_area.uid
	if (name == "alarm")
		name = "[alarm_area.name] Air Alarm"

	if(!wires)
		wires = new(src)

	// breathable air according to human/Life()
	TLV["oxygen"] =			list(16, 19, 135, 140) // Partial pressure, kpa
	TLV["carbon dioxide"] = list(-1.0, -1.0, 5, 10) // Partial pressure, kpa
	TLV["phoron"] =			list(-1.0, -1.0, 0.2, 0.5) // Partial pressure, kpa
	TLV["other"] =			list(-1.0, -1.0, 0.5, 1.0) // Partial pressure, kpa
	TLV["pressure"] =		list(ONE_ATMOSPHERE*0.80,ONE_ATMOSPHERE*0.90,ONE_ATMOSPHERE*1.10,ONE_ATMOSPHERE*1.20) /* kpa */
	TLV["temperature"] =	list(T0C-26, T0C, T0C+40, T0C+66) // K


/obj/machinery/alarm/initialize()
	set_frequency(frequency)
	if (!master_is_operating())
		elect_master()

/obj/machinery/alarm/process()
	if((stat & (NOPOWER|BROKEN)) || shorted || buildstage != 2)
		return

	var/turf/simulated/location = loc
	if(!istype(location))	return//returns if loc is not simulated

	var/datum/gas_mixture/environment = location.return_air()

	//Handle temperature adjustment here.
	handle_heating_cooling(environment)

	var/old_level = danger_level
	var/old_pressurelevel = pressure_dangerlevel
	danger_level = overall_danger_level(environment)

	if (old_level != danger_level)
		apply_danger_level(danger_level)

	if (old_pressurelevel != pressure_dangerlevel)
		if (breach_detected())
			mode = AALARM_MODE_OFF
			apply_mode()

	if (mode==AALARM_MODE_CYCLE && environment.return_pressure()<ONE_ATMOSPHERE*0.05)
		mode=AALARM_MODE_FILL
		apply_mode()

	//atmos computer remote controll stuff
	switch(rcon_setting)
		if(RCON_NO)
			remote_control = 0
		if(RCON_AUTO)
			if(danger_level == 2)
				remote_control = 1
			else
				remote_control = 0
		if(RCON_YES)
			remote_control = 1

	updateDialog()
	return

/obj/machinery/alarm/proc/handle_heating_cooling(var/datum/gas_mixture/environment)
	if (!regulating_temperature)
		//check for when we should start adjusting temperature
		if(!get_danger_level(target_temperature, TLV["temperature"]) && abs(environment.temperature - target_temperature) > 2.0)
			update_use_power(2)
			regulating_temperature = 1
			visible_message("\The [src] clicks as it starts [environment.temperature > target_temperature ? "cooling" : "heating"] the room.",\
			"You hear a click and a faint electronic hum.")
	else
		//check for when we should stop adjusting temperature
		if (get_danger_level(target_temperature, TLV["temperature"]) || abs(environment.temperature - target_temperature) <= 0.5)
			update_use_power(1)
			regulating_temperature = 0
			visible_message("\The [src] clicks quietly as it stops [environment.temperature > target_temperature ? "cooling" : "heating"] the room.",\
			"You hear a click as a faint electronic humming stops.")

	if (regulating_temperature)
		if(target_temperature > T0C + MAX_TEMPERATURE)
			target_temperature = T0C + MAX_TEMPERATURE

		if(target_temperature < T0C + MIN_TEMPERATURE)
			target_temperature = T0C + MIN_TEMPERATURE

		var/datum/gas_mixture/gas
		gas = environment.remove(0.25*environment.total_moles)
		if(gas)

			if (gas.temperature <= target_temperature)	//gas heating
				var/energy_used = min( gas.get_thermal_energy_change(target_temperature) , active_power_usage)

				gas.add_thermal_energy(energy_used)
				//use_power(energy_used, ENVIRON) //handle by update_use_power instead
			else	//gas cooling
				var/heat_transfer = min(abs(gas.get_thermal_energy_change(target_temperature)), active_power_usage)

				//Assume the heat is being pumped into the hull which is fixed at 20 C
				//none of this is really proper thermodynamics but whatever

				var/cop = gas.temperature/T20C	//coefficient of performance -> power used = heat_transfer/cop

				heat_transfer = min(heat_transfer, cop * active_power_usage)	//this ensures that we don't use more than active_power_usage amount of power

				heat_transfer = -gas.add_thermal_energy(-heat_transfer)	//get the actual heat transfer

				//use_power(heat_transfer / cop, ENVIRON)	//handle by update_use_power instead

			environment.merge(gas)

/obj/machinery/alarm/proc/overall_danger_level(var/datum/gas_mixture/environment)
	var/partial_pressure = R_IDEAL_GAS_EQUATION*environment.temperature/environment.volume
	var/environment_pressure = environment.return_pressure()
	//var/other_moles = 0.0
	////for(var/datum/gas/G in environment.trace_gases)
	//	other_moles+=G.moles

	pressure_dangerlevel = get_danger_level(environment_pressure, TLV["pressure"])
	oxygen_dangerlevel = get_danger_level(environment.gas["oxygen"]*partial_pressure, TLV["oxygen"])
	co2_dangerlevel = get_danger_level(environment.gas["carbon_dioxide"]*partial_pressure, TLV["carbon dioxide"])
	phoron_dangerlevel = get_danger_level(environment.gas["phoron"]*partial_pressure, TLV["phoron"])
	temperature_dangerlevel = get_danger_level(environment.temperature, TLV["temperature"])
	//other_dangerlevel = get_danger_level(other_moles*partial_pressure, TLV["other"])

	return max(
		pressure_dangerlevel,
		oxygen_dangerlevel,
		co2_dangerlevel,
		phoron_dangerlevel,
		//other_dangerlevel,
		temperature_dangerlevel
		)

// Returns whether this air alarm thinks there is a breach, given the sensors that are available to it.
/obj/machinery/alarm/proc/breach_detected()
	var/turf/simulated/location = loc

	if(!istype(location))
		return 0

	if(breach_detection	== 0)
		return 0

	var/datum/gas_mixture/environment = location.return_air()
	var/environment_pressure = environment.return_pressure()
	var/pressure_levels = TLV["pressure"]

	if (environment_pressure <= pressure_levels[1])		//low pressures
		if (!(mode == AALARM_MODE_PANIC || mode == AALARM_MODE_CYCLE))
			return 1

	return 0


/obj/machinery/alarm/proc/master_is_operating()
	return alarm_area.master_air_alarm && !(alarm_area.master_air_alarm.stat & (NOPOWER|BROKEN))


/obj/machinery/alarm/proc/elect_master()
	for (var/obj/machinery/alarm/AA in alarm_area)
		if (!(AA.stat & (NOPOWER|BROKEN)))
			alarm_area.master_air_alarm = AA
			return 1
	return 0

/obj/machinery/alarm/proc/get_danger_level(var/current_value, var/list/danger_levels)
	if((current_value >= danger_levels[4] && danger_levels[4] > 0) || current_value <= danger_levels[1])
		return 2
	if((current_value >= danger_levels[3] && danger_levels[3] > 0) || current_value <= danger_levels[2])
		return 1
	return 0

/obj/machinery/alarm/update_icon()
	if(wiresexposed)
		icon_state = "alarmx"
		return
	if((stat & (NOPOWER|BROKEN)) || shorted)
		icon_state = "alarmp"
		return

	var/icon_level = danger_level
	if (alarm_area.atmosalm)
		icon_level = max(icon_level, 1)	//if there's an atmos alarm but everything is okay locally, no need to go past yellow

	switch(icon_level)
		if (0)
			icon_state = "alarm0"
		if (1)
			icon_state = "alarm2" //yes, alarm2 is yellow alarm
		if (2)
			icon_state = "alarm1"

/obj/machinery/alarm/receive_signal(datum/signal/signal)
	if(stat & (NOPOWER|BROKEN))
		return
	if (alarm_area.master_air_alarm != src)
		if (master_is_operating())
			return
		elect_master()
		if (alarm_area.master_air_alarm != src)
			return
	if(!signal || signal.encryption)
		return
	var/id_tag = signal.data["tag"]
	if (!id_tag)
		return
	if (signal.data["area"] != area_uid)
		return
	if (signal.data["sigtype"] != "status")
		return

	var/dev_type = signal.data["device"]
	if(!(id_tag in alarm_area.air_scrub_names) && !(id_tag in alarm_area.air_vent_names))
		register_env_machine(id_tag, dev_type)
	if(dev_type == "AScr")
		alarm_area.air_scrub_info[id_tag] = signal.data
	else if(dev_type == "AVP")
		alarm_area.air_vent_info[id_tag] = signal.data

/obj/machinery/alarm/proc/register_env_machine(var/m_id, var/device_type)
	var/new_name
	if (device_type=="AVP")
		new_name = "[alarm_area.name] Vent Pump #[alarm_area.air_vent_names.len+1]"
		alarm_area.air_vent_names[m_id] = new_name
	else if (device_type=="AScr")
		new_name = "[alarm_area.name] Air Scrubber #[alarm_area.air_scrub_names.len+1]"
		alarm_area.air_scrub_names[m_id] = new_name
	else
		return
	spawn (10)
		send_signal(m_id, list("init" = new_name) )

/obj/machinery/alarm/proc/refresh_all()
	for(var/id_tag in alarm_area.air_vent_names)
		var/list/I = alarm_area.air_vent_info[id_tag]
		if (I && I["timestamp"]+AALARM_REPORT_TIMEOUT/2 > world.time)
			continue
		send_signal(id_tag, list("status") )
	for(var/id_tag in alarm_area.air_scrub_names)
		var/list/I = alarm_area.air_scrub_info[id_tag]
		if (I && I["timestamp"]+AALARM_REPORT_TIMEOUT/2 > world.time)
			continue
		send_signal(id_tag, list("status") )

/obj/machinery/alarm/proc/set_frequency(new_frequency)
	radio_controller.remove_object(src, frequency)
	frequency = new_frequency
	radio_connection = radio_controller.add_object(src, frequency, RADIO_TO_AIRALARM)

/obj/machinery/alarm/proc/send_signal(var/target, var/list/command)//sends signal 'command' to 'target'. Returns 0 if no radio connection, 1 otherwise
	if(!radio_connection)
		return 0

	var/datum/signal/signal = new
	signal.transmission_method = 1 //radio signal
	signal.source = src

	signal.data = command
	signal.data["tag"] = target
	signal.data["sigtype"] = "command"

	radio_connection.post_signal(src, signal, RADIO_FROM_AIRALARM)
//			world << text("Signal [] Broadcasted to []", command, target)

	return 1

/obj/machinery/alarm/proc/apply_mode()
	//propagate mode to other air alarms in the area
	//TODO: make it so that players can choose between applying the new mode to the room they are in (related area) vs the entire alarm area
	for (var/obj/machinery/alarm/AA in alarm_area)
		AA.mode = mode

	switch(mode)
		if(AALARM_MODE_SCRUBBING)
			for(var/device_id in alarm_area.air_scrub_names)
				send_signal(device_id, list("power"= 1, "co2_scrub"= 1, "scrubbing"= 1, "panic_siphon"= 0) )
			for(var/device_id in alarm_area.air_vent_names)
				send_signal(device_id, list("power"= 1, "checks"= "default", "set_external_pressure"= "default") )

		if(AALARM_MODE_PANIC, AALARM_MODE_CYCLE)
			for(var/device_id in alarm_area.air_scrub_names)
				send_signal(device_id, list("power"= 1, "panic_siphon"= 1) )
			for(var/device_id in alarm_area.air_vent_names)
				send_signal(device_id, list("power"= 0) )

		if(AALARM_MODE_REPLACEMENT)
			for(var/device_id in alarm_area.air_scrub_names)
				send_signal(device_id, list("power"= 1, "panic_siphon"= 1) )
			for(var/device_id in alarm_area.air_vent_names)
				send_signal(device_id, list("power"= 1, "checks"= "default", "set_external_pressure"= "default") )

		if(AALARM_MODE_FILL)
			for(var/device_id in alarm_area.air_scrub_names)
				send_signal(device_id, list("power"= 0) )
			for(var/device_id in alarm_area.air_vent_names)
				send_signal(device_id, list("power"= 1, "checks"= "default", "set_external_pressure"= "default") )

		if(AALARM_MODE_OFF)
			for(var/device_id in alarm_area.air_scrub_names)
				send_signal(device_id, list("power"= 0) )
			for(var/device_id in alarm_area.air_vent_names)
				send_signal(device_id, list("power"= 0) )

/obj/machinery/alarm/proc/apply_danger_level(var/new_danger_level)
	if (report_danger_level && alarm_area.atmosalert(new_danger_level))
		post_alert(new_danger_level)

	update_icon()

/obj/machinery/alarm/proc/post_alert(alert_level)
	var/datum/radio_frequency/frequency = radio_controller.return_frequency(alarm_frequency)
	if(!frequency)
		return

	playsound(src.loc, 'sound/machines/airalarm.ogg', 75, 0)

	var/datum/signal/alert_signal = new
	alert_signal.source = src
	alert_signal.transmission_method = 1
	alert_signal.data["zone"] = alarm_area.name
	alert_signal.data["type"] = "Atmospheric"

	if(alert_level==2)
		alert_signal.data["alert"] = "severe"
	else if (alert_level==1)
		alert_signal.data["alert"] = "minor"
	else if (alert_level==0)
		alert_signal.data["alert"] = "clear"

	frequency.post_signal(src, alert_signal)

/obj/machinery/alarm/attack_ai(mob/user)
	return interact(user)

/obj/machinery/alarm/attack_hand(mob/user)
	. = ..()
	if (.)
		return
	return interact(user)

/obj/machinery/alarm/interact(mob/user)
	user.set_machine(src)

	if(buildstage!=2)
		return

	if((get_dist(src, user) > 1 ))
		if (!istype(user, /mob/living/silicon))
			user.machine = null
			user << browse(null, "window=air_alarm")
			user << browse(null, "window=AAlarmwires")
			return


		else if (istype(user, /mob/living/silicon) && aidisabled)
			user << "AI control for this Air Alarm interface has been disabled."
			user << browse(null, "window=air_alarm")
			return

	if(wiresexposed && (!istype(user, /mob/living/silicon/ai)))
		wires.Interact(user)

	if(!shorted)
		user << browse(return_text(user),"window=air_alarm")
		onclose(user, "air_alarm")

	return

/obj/machinery/alarm/proc/return_text(mob/user)
	if(!(istype(user, /mob/living/silicon)) && locked)
		return "<html><head><title>\The [src]</title></head><body>[return_status()]<hr>[rcon_text()]<hr><i>(Swipe ID card to unlock interface)</i></body></html>"
	else
		return "<html><head><title>\The [src]</title></head><body>[return_status()]<hr>[rcon_text()]<hr>[return_controls()]</body></html>"

/obj/machinery/alarm/proc/return_status()
	var/turf/location = get_turf(src)
	var/datum/gas_mixture/environment = location.return_air()
	var/total = environment.total_moles
	var/output = "<b>Air Status:</b><br>"

	if(total == 0)
		output += "<font color='red'><b>Warning: Cannot obtain air sample for analysis.</b></font>"
		return output

	output += {"
<style>
.dl0 { color: green; }
.dl1 { color: orange; }
.dl2 { color: red; font-weght: bold;}
</style>
"}

	var/partial_pressure = R_IDEAL_GAS_EQUATION*environment.temperature/environment.volume

	var/list/current_settings = TLV["pressure"]
	var/environment_pressure = environment.return_pressure()
	var/pressure_dangerlevel = get_danger_level(environment_pressure, current_settings)

	current_settings = TLV["oxygen"]
	var/oxygen_dangerlevel = get_danger_level(environment.gas["oxygen"]*partial_pressure, current_settings)
	var/oxygen_percent = round(environment.gas["oxygen"] / total * 100, 2)

	current_settings = TLV["carbon dioxide"]
	var/co2_dangerlevel = get_danger_level(environment.gas["carbon_dioxide"]*partial_pressure, current_settings)
	var/co2_percent = round(environment.gas["carbon_dioxide"] / total * 100, 2)

	current_settings = TLV["phoron"]
	var/phoron_dangerlevel = get_danger_level(environment.gas["phoron"]*partial_pressure, current_settings)
	var/phoron_percent = round(environment.gas["phoron"] / total * 100, 2)

	//current_settings = TLV["other"]
	//var/other_moles = 0.0
	//for(var/datum/gas/G in environment.trace_gases)
	//	other_moles+=G.moles
	//var/other_dangerlevel = get_danger_level(other_moles*partial_pressure, current_settings)

	current_settings = TLV["temperature"]
	var/temperature_dangerlevel = get_danger_level(environment.temperature, current_settings)

	output += {"
Pressure: <span class='dl[pressure_dangerlevel]'>[environment_pressure]</span>kPa<br>
Oxygen: <span class='dl[oxygen_dangerlevel]'>[oxygen_percent]</span>%<br>
Carbon dioxide: <span class='dl[co2_dangerlevel]'>[co2_percent]</span>%<br>
Toxins: <span class='dl[phoron_dangerlevel]'>[phoron_percent]</span>%<br>
"}
	//if (other_dangerlevel==2)
	//	output += "Notice: <span class='dl2'>High Concentration of Unknown Particles Detected</span><br>"
	//else if (other_dangerlevel==1)
	//	output += "Notice: <span class='dl1'>Low Concentration of Unknown Particles Detected</span><br>"

	output += "Temperature: <span class='dl[temperature_dangerlevel]'>[environment.temperature]</span>K ([round(environment.temperature - T0C, 0.1)]C)<br>"

	//'Local Status' should report the LOCAL status, damnit.
	output += "Local Status: "
	switch(max(pressure_dangerlevel,oxygen_dangerlevel,co2_dangerlevel,phoron_dangerlevel,other_dangerlevel,temperature_dangerlevel))
		if(2)
			output += "<span class='dl2'>DANGER: Internals Required</span><br>"
		if(1)
			output += "<span class='dl1'>Caution</span><br>"
		if(0)
			output += "<span class='dl0'>Optimal</span><br>"

	output += "Area Status: "
	if(alarm_area.atmosalm)
		output += "<span class='dl1'>Atmos alert in area</span>"
	else if (alarm_area.fire)
		output += "<span class='dl1'>Fire alarm in area</span>"
	else
		output += "No alerts"

	return output

/obj/machinery/alarm/proc/rcon_text()
	var/dat = "<table width=\"100%\"><td align=\"center\"><b>Remote Control:</b><br>"
	if(rcon_setting == RCON_NO)
		dat += "<b>Off</b>"
	else
		dat += "<a href='?src=\ref[src];rcon=[RCON_NO]'>Off</a>"
	dat += " | "
	if(rcon_setting == RCON_AUTO)
		dat += "<b>Auto</b>"
	else
		dat += "<a href='?src=\ref[src];rcon=[RCON_AUTO]'>Auto</a>"
	dat += " | "
	if(rcon_setting == RCON_YES)
		dat += "<b>On</b>"
	else
		dat += "<a href='?src=\ref[src];rcon=[RCON_YES]'>On</a></td>"

	//Hackish, I know.  I didn't feel like bothering to rework all of this.
	dat += "<td align=\"center\"><b>Thermostat:</b><br><a href='?src=\ref[src];temperature=1'>[target_temperature - T0C]C</a></td></table>"

	return dat

/obj/machinery/alarm/proc/return_controls(var/source = src)
	var/output = ""//"<B>[alarm_zone] Air [name]</B><HR>"

	switch(screen)
		if (AALARM_SCREEN_MAIN)
			if(alarm_area.atmosalm)
				output += "<a href='?src=\ref[source];atmos_reset=1'>Reset - Area Atmospheric Alarm</a><hr>"
			else
				output += "<a href='?src=\ref[source];atmos_alarm=1'>Activate - Area Atmospheric Alarm</a><hr>"

			output += {"
<a href='?src=\ref[source];screen=[AALARM_SCREEN_SCRUB]'>Scrubbers Control</a><br>
<a href='?src=\ref[source];screen=[AALARM_SCREEN_VENT]'>Vents Control</a><br>
<a href='?src=\ref[source];screen=[AALARM_SCREEN_MODE]'>Set environmentals mode</a><br>
<a href='?src=\ref[source];screen=[AALARM_SCREEN_SENSORS]'>Sensor Settings</a><br>
<HR>
"}
			if (mode==AALARM_MODE_PANIC)
				output += "<font color='red'><B>PANIC SYPHON ACTIVE</B></font><br><A href='?src=\ref[source];mode=[AALARM_MODE_SCRUBBING]'>Turn syphoning off</A>"
			else
				output += "<A href='?src=\ref[source];mode=[AALARM_MODE_PANIC]'><font color='red'>ACTIVATE PANIC SYPHON IN AREA</font></A>"


		if (AALARM_SCREEN_VENT)
			var/sensor_data = ""
			if(alarm_area.air_vent_names.len)
				for(var/id_tag in alarm_area.air_vent_names)
					var/long_name = alarm_area.air_vent_names[id_tag]
					var/list/data = alarm_area.air_vent_info[id_tag]
					if(!data)
						continue;
					var/state = ""

					sensor_data += {"
<B>[long_name]</B>[state]<BR>
<B>Operating:</B>
<A href='?src=\ref[source];id_tag=[id_tag];command=power;val=[!data["power"]]'>[data["power"]?"on":"off"]</A>
<BR>
<B>Pressure checks:</B>
<A href='?src=\ref[source];id_tag=[id_tag];command=checks;val=[data["checks"]^1]' [(data["checks"]&1)?"style='font-weight:bold;'":""]>external</A>
<A href='?src=\ref[source];id_tag=[id_tag];command=checks;val=[data["checks"]^2]' [(data["checks"]&2)?"style='font-weight:bold;'":""]>internal</A>
<BR>
<B>External pressure bound:</B>
<A href='?src=\ref[source];id_tag=[id_tag];command=adjust_external_pressure;val=-1000'>-</A>
<A href='?src=\ref[source];id_tag=[id_tag];command=adjust_external_pressure;val=-100'>-</A>
<A href='?src=\ref[source];id_tag=[id_tag];command=adjust_external_pressure;val=-10'>-</A>
<A href='?src=\ref[source];id_tag=[id_tag];command=adjust_external_pressure;val=-1'>-</A>
[data["external"]]
<A href='?src=\ref[source];id_tag=[id_tag];command=adjust_external_pressure;val=+1'>+</A>
<A href='?src=\ref[source];id_tag=[id_tag];command=adjust_external_pressure;val=+10'>+</A>
<A href='?src=\ref[source];id_tag=[id_tag];command=adjust_external_pressure;val=+100'>+</A>
<A href='?src=\ref[source];id_tag=[id_tag];command=adjust_external_pressure;val=+1000'>+</A>
<A href='?src=\ref[source];id_tag=[id_tag];command=set_external_pressure;val=[ONE_ATMOSPHERE]'> (reset) </A>
<BR>
"}
					if (data["direction"] == "siphon")
						sensor_data += {"
<B>Direction:</B>
siphoning
<BR>
"}
					sensor_data += {"<HR>"}
			else
				sensor_data = "No vents connected.<BR>"
			output = {"<a href='?src=\ref[source];screen=[AALARM_SCREEN_MAIN]'>Main menu</a><br>[sensor_data]"}
		if (AALARM_SCREEN_SCRUB)
			var/sensor_data = ""
			if(alarm_area.air_scrub_names.len)
				for(var/id_tag in alarm_area.air_scrub_names)
					var/long_name = alarm_area.air_scrub_names[id_tag]
					var/list/data = alarm_area.air_scrub_info[id_tag]
					if(!data)
						continue;
					var/state = ""

					sensor_data += {"
<B>[long_name]</B>[state]<BR>
<B>Operating:</B>
<A href='?src=\ref[source];id_tag=[id_tag];command=power;val=[!data["power"]]'>[data["power"]?"on":"off"]</A><BR>
<B>Type:</B>
<A href='?src=\ref[source];id_tag=[id_tag];command=scrubbing;val=[!data["scrubbing"]]'>[data["scrubbing"]?"scrubbing":"syphoning"]</A><BR>
"}

					if(data["scrubbing"])
						sensor_data += {"
<B>Filtering:</B>
Carbon Dioxide
<A href='?src=\ref[source];id_tag=[id_tag];command=co2_scrub;val=[!data["filter_co2"]]'>[data["filter_co2"]?"on":"off"]</A>;
Toxins
<A href='?src=\ref[source];id_tag=[id_tag];command=tox_scrub;val=[!data["filter_phoron"]]'>[data["filter_phoron"]?"on":"off"]</A>;
Nitrous Oxide
<A href='?src=\ref[source];id_tag=[id_tag];command=n2o_scrub;val=[!data["filter_n2o"]]'>[data["filter_n2o"]?"on":"off"]</A>
<BR>
"}
					sensor_data += {"
<B>Panic syphon:</B> [data["panic"]?"<font color='red'><B>PANIC SYPHON ACTIVATED</B></font>":""]
<A href='?src=\ref[source];id_tag=[id_tag];command=panic_siphon;val=[!data["panic"]]'><font color='[(data["panic"]?"blue'>Dea":"red'>A")]ctivate</font></A><BR>
<HR>
"}
			else
				sensor_data = "No scrubbers connected.<BR>"
			output = {"<a href='?src=\ref[source];screen=[AALARM_SCREEN_MAIN]'>Main menu</a><br>[sensor_data]"}

		if (AALARM_SCREEN_MODE)
			output += "<a href='?src=\ref[source];screen=[AALARM_SCREEN_MAIN]'>Main menu</a><br><b>Air machinery mode for the area:</b><ul>"
			var/list/modes = list(AALARM_MODE_SCRUBBING   = "Filtering - Scrubs out contaminants",\
				AALARM_MODE_REPLACEMENT = "<font color='blue'>Replace Air - Siphons out air while replacing</font>",\
				AALARM_MODE_PANIC       = "<font color='red'>Panic - Siphons air out of the room</font>",\
				AALARM_MODE_CYCLE       = "<font color='red'>Cycle - Siphons air before replacing</font>",\
				AALARM_MODE_FILL        = "<font color='green'>Fill - Shuts off scrubbers and opens vents</font>",\
				AALARM_MODE_OFF         = "<font color='blue'>Off - Shuts off vents and scrubbers</font>",)
			for (var/m=1,m<=modes.len,m++)
				if (mode==m)
					output += "<li><A href='?src=\ref[source];mode=[m]'><b>[modes[m]]</b></A> (selected)</li>"
				else
					output += "<li><A href='?src=\ref[source];mode=[m]'>[modes[m]]</A></li>"
			output += "</ul>"

		if (AALARM_SCREEN_SENSORS)
			output += {"
<a href='?src=\ref[source];screen=[AALARM_SCREEN_MAIN]'>Main menu</a><br>
<b>Alarm thresholds:</b><br>
Partial pressure for gases
<style>/* some CSS woodoo here. Does not work perfect in ie6 but who cares? */
table td { border-left: 1px solid black; border-top: 1px solid black;}
table tr:first-child th { border-left: 1px solid black;}
table th:first-child { border-top: 1px solid black; font-weight: normal;}
table tr:first-child th:first-child { border: none;}
.dl0 { color: green; }
.dl1 { color: orange; }
.dl2 { color: red; font-weght: bold;}
</style>
<table cellspacing=0>
<TR><th></th><th class=dl2>min2</th><th class=dl1>min1</th><th class=dl1>max1</th><th class=dl2>max2</th></TR>
"}
			var/list/gases = list(
				"oxygen"         = "O<sub>2</sub>",
				"carbon dioxide" = "CO<sub>2</sub>",
				"phoron"         = "Toxin",
				"other"          = "Other",)

			var/list/selected
			for (var/g in gases)
				output += "<TR><th>[gases[g]]</th>"
				selected = TLV[g]
				for(var/i = 1, i <= 4, i++)
					output += "<td><A href='?src=\ref[source];command=set_threshold;env=[g];var=[i]'>[selected[i] >= 0 ? selected[i] :"OFF"]</A></td>"
				output += "</TR>"

			selected = TLV["pressure"]
			output += "	<TR><th>Pressure</th>"
			for(var/i = 1, i <= 4, i++)
				output += "<td><A href='?src=\ref[source];command=set_threshold;env=pressure;var=[i]'>[selected[i] >= 0 ? selected[i] :"OFF"]</A></td>"
			output += "</TR>"

			selected = TLV["temperature"]
			output += "<TR><th>Temperature</th>"
			for(var/i = 1, i <= 4, i++)
				output += "<td><A href='?src=\ref[source];command=set_threshold;env=temperature;var=[i]'>[selected[i] >= 0 ? selected[i] :"OFF"]</A></td>"
			output += "</TR></table>"

	return output

/obj/machinery/alarm/Topic(href, href_list, var/nowindow = 0, var/remote = 0)
	if(..(href, href_list, nowindow, !remote) || !( Adjacent(usr) || nowindow || istype(usr, /mob/living/silicon)) ) // dont forget calling super in machine Topics -walter0o
		usr.machine = null
		usr << browse(null, "window=air_alarm")
		usr << browse(null, "window=AAlarmwires")
		return

	add_fingerprint(usr)
	usr.set_machine(src)

	// hrefs that can always be called -walter0o
	if(href_list["rcon"])
		var/attempted_rcon_setting = text2num(href_list["rcon"])

		switch(attempted_rcon_setting)
			if(RCON_NO)
				rcon_setting = RCON_NO
			if(RCON_AUTO)
				rcon_setting = RCON_AUTO
			if(RCON_YES)
				rcon_setting = RCON_YES
			else
				return

	if(href_list["temperature"])
		var/list/selected = TLV["temperature"]
		var/max_temperature = min(selected[3] - T0C, MAX_TEMPERATURE)
		var/min_temperature = max(selected[2] - T0C, MIN_TEMPERATURE)
		var/input_temperature = input("What temperature would you like the system to mantain? (Capped between [min_temperature]C and [max_temperature]C)", "Thermostat Controls") as num|null
		if(!input_temperature || input_temperature > max_temperature || input_temperature < min_temperature)
			usr << "Temperature must be between [min_temperature]C and [max_temperature]C"
		else
			target_temperature = input_temperature + T0C

	// hrefs that need the AA unlocked -walter0o
	if(!locked || remote || istype(usr, /mob/living/silicon))

		if(href_list["command"])
			var/device_id = href_list["id_tag"]
			switch(href_list["command"])
				if( "power",
					"adjust_external_pressure",
					"set_external_pressure",
					"checks",
					"co2_scrub",
					"tox_scrub",
					"n2o_scrub",
					"panic_siphon",
					"scrubbing")

					send_signal(device_id, list(href_list["command"] = text2num(href_list["val"]) ) )

				if("set_threshold")
					var/env = href_list["env"]
					var/threshold = text2num(href_list["var"])
					var/list/selected = TLV[env]
					var/list/thresholds = list("lower bound", "low warning", "high warning", "upper bound")
					var/newval = input("Enter [thresholds[threshold]] for [env]", "Alarm triggers", selected[threshold]) as null|num
					if (isnull(newval))
						return
					if (newval<0)
						selected[threshold] = -1.0
					else if (env=="temperature" && newval>5000)
						selected[threshold] = 5000
					else if (env=="pressure" && newval>50*ONE_ATMOSPHERE)
						selected[threshold] = 50*ONE_ATMOSPHERE
					else if (env!="temperature" && env!="pressure" && newval>200)
						selected[threshold] = 200
					else
						newval = round(newval,0.01)
						selected[threshold] = newval
					if(threshold == 1)
						if(selected[1] > selected[2])
							selected[2] = selected[1]
						if(selected[1] > selected[3])
							selected[3] = selected[1]
						if(selected[1] > selected[4])
							selected[4] = selected[1]
					if(threshold == 2)
						if(selected[1] > selected[2])
							selected[1] = selected[2]
						if(selected[2] > selected[3])
							selected[3] = selected[2]
						if(selected[2] > selected[4])
							selected[4] = selected[2]
					if(threshold == 3)
						if(selected[1] > selected[3])
							selected[1] = selected[3]
						if(selected[2] > selected[3])
							selected[2] = selected[3]
						if(selected[3] > selected[4])
							selected[4] = selected[3]
					if(threshold == 4)
						if(selected[1] > selected[4])
							selected[1] = selected[4]
						if(selected[2] > selected[4])
							selected[2] = selected[4]
						if(selected[3] > selected[4])
							selected[3] = selected[4]

					apply_mode()

		if(href_list["screen"])
			screen = text2num(href_list["screen"])

		if(href_list["atmos_unlock"])
			switch(href_list["atmos_unlock"])
				if("0")
					alarm_area.air_doors_close()
				if("1")
					alarm_area.air_doors_open()

		if(href_list["atmos_alarm"])
			if (alarm_area.atmosalert(2))
				apply_danger_level(2)
			update_icon()

		if(href_list["atmos_reset"])
			if (alarm_area.atmosalert(0))
				apply_danger_level(0)
			update_icon()

		if(href_list["mode"])
			mode = text2num(href_list["mode"])
			apply_mode()

	if(!nowindow)
		updateUsrDialog()


/obj/machinery/alarm/attackby(obj/item/W as obj, mob/user as mob)
	src.add_fingerprint(user)

	switch(buildstage)
		if(2)
			if(istype(W, /obj/item/weapon/screwdriver))  // Opening that Air Alarm up.
				//user << "You pop the Air Alarm's maintence panel open."
				wiresexposed = !wiresexposed
				user << "The wires have been [wiresexposed ? "exposed" : "unexposed"]"
				update_icon()
				return

			if (wiresexposed && istype(W, /obj/item/weapon/wirecutters))
				user.visible_message("<span class='warning'>[user] has cut the wires inside \the [src]!</span>", "You have cut the wires inside \the [src].")
				playsound(src.loc, 'sound/items/Wirecutter.ogg', 50, 1)
				new/obj/item/stack/cable_coil(get_turf(src), 5)
				buildstage = 1
				update_icon()
				return

			if (istype(W, /obj/item/weapon/card/id) || istype(W, /obj/item/device/pda))// trying to unlock the interface with an ID card
				if(stat & (NOPOWER|BROKEN))
					user << "It does nothing"
					return
				else
					if(allowed(usr) && !wires.IsIndexCut(AALARM_WIRE_IDSCAN))
						locked = !locked
						user << "\blue You [ locked ? "lock" : "unlock"] the Air Alarm interface."
						updateUsrDialog()
					else
						user << "\red Access denied."
			return

		if(1)
			if(istype(W, /obj/item/stack/cable_coil))
				var/obj/item/stack/cable_coil/C = W
				if (C.use(5))
					user << "<span class='notice'>You wire \the [src].</span>"
					buildstage = 2
					update_icon()
					first_run()
					return
				else
					user << "<span class='warning'>You need 5 pieces of cable to do wire \the [src].</span>"
					return

			else if(istype(W, /obj/item/weapon/crowbar))
				user << "You start prying out the circuit."
				playsound(src.loc, 'sound/items/Crowbar.ogg', 50, 1)
				if(do_after(user,20))
					user << "You pry out the circuit!"
					var/obj/item/weapon/airalarm_electronics/circuit = new /obj/item/weapon/airalarm_electronics()
					circuit.loc = user.loc
					buildstage = 0
					update_icon()
				return
		if(0)
			if(istype(W, /obj/item/weapon/airalarm_electronics))
				user << "You insert the circuit!"
				qdel(W)
				buildstage = 1
				update_icon()
				return

			else if(istype(W, /obj/item/weapon/wrench))
				user << "You remove the fire alarm assembly from the wall!"
				var/obj/item/alarm_frame/frame = new /obj/item/alarm_frame()
				frame.loc = user.loc
				playsound(src.loc, 'sound/items/Ratchet.ogg', 50, 1)
				qdel(src)

	return ..()

/obj/machinery/alarm/power_change()
	..()
	spawn(rand(0,15))
		update_icon()

/obj/machinery/alarm/examine(mob/user)
	..(user)
	if (buildstage < 2)
		user << "It is not wired."
	if (buildstage < 1)
		user << "The circuit is missing."
/*
AIR ALARM CIRCUIT
Just a object used in constructing air alarms
*/
/obj/item/weapon/airalarm_electronics
	name = "air alarm electronics"
	icon = 'icons/obj/doors/door_assembly.dmi'
	icon_state = "door_electronics"
	desc = "Looks like a circuit. Probably is."
	w_class = 2.0
	matter = list("metal" = 50, "glass" = 50)


/*
AIR ALARM ITEM
Handheld air alarm frame, for placing on walls
Code shamelessly copied from apc_frame
*/
/obj/item/alarm_frame
	name = "air alarm frame"
	desc = "Used for building Air Alarms"
	icon = 'icons/obj/monitors.dmi'
	icon_state = "alarm_bitem"
	flags = CONDUCT

/obj/item/alarm_frame/attackby(obj/item/weapon/W as obj, mob/user as mob)
	if (istype(W, /obj/item/weapon/wrench))
		new /obj/item/stack/sheet/metal( get_turf(src.loc), 2 )
		qdel(src)
		return
	..()

/obj/item/alarm_frame/proc/try_build(turf/on_wall)
	if (get_dist(on_wall,usr)>1)
		return

	var/ndir = get_dir(on_wall,usr)
	if (!(ndir in cardinal))
		return

	var/turf/loc = get_turf(usr)
	var/area/A = loc.loc
	if (!istype(loc, /turf/simulated/floor))
		usr << "\red Air Alarm cannot be placed on this spot."
		return
	if (A.requires_power == 0 || A.name == "Space")
		usr << "\red Air Alarm cannot be placed in this area."
		return

	if(gotwallitem(loc, ndir))
		usr << "\red There's already an item on this wall!"
		return

	new /obj/machinery/alarm(loc, ndir, 1)
	qdel(src)

/*
FIRE ALARM
*/
/obj/machinery/firealarm
	name = "fire alarm"
	desc = "<i>\"Pull this in case of emergency\"</i>. Thus, keep pulling it forever."
	icon = 'icons/obj/monitors.dmi'
	icon_state = "fire0"
	var/detecting = 1.0
	var/working = 1.0
	var/time = 10.0
	var/timing = 0.0
	var/lockdownbyai = 0
	anchored = 1.0
	use_power = 1
	idle_power_usage = 2
	active_power_usage = 6
	power_channel = ENVIRON
	var/last_process = 0
	var/wiresexposed = 0
	var/buildstage = 2 // 2 = complete, 1 = no wires,  0 = circuit gone

/obj/machinery/firealarm/update_icon()

	if(wiresexposed)
		switch(buildstage)
			if(2)
				icon_state="fire_b2"
			if(1)
				icon_state="fire_b1"
			if(0)
				icon_state="fire_b0"

		return

	if(stat & BROKEN)
		icon_state = "firex"
	else if(stat & NOPOWER)
		icon_state = "firep"
	else if(!src.detecting)
		icon_state = "fire1"
	else
		icon_state = "fire0"

/obj/machinery/firealarm/fire_act(datum/gas_mixture/air, temperature, volume)
	if(src.detecting)
		if(temperature > T0C+200)
			src.alarm()			// added check of detector status here
	return

/obj/machinery/firealarm/attack_ai(mob/user as mob)
	return src.attack_hand(user)

/obj/machinery/firealarm/bullet_act(BLAH)
	return src.alarm()

/obj/machinery/firealarm/emp_act(severity)
	if(prob(50/severity)) alarm()
	..()

/obj/machinery/firealarm/attackby(obj/item/W as obj, mob/user as mob)
	src.add_fingerprint(user)

	if (istype(W, /obj/item/weapon/screwdriver) && buildstage == 2)
		wiresexposed = !wiresexposed
		update_icon()
		return

	if(wiresexposed)
		switch(buildstage)
			if(2)
				if (istype(W, /obj/item/device/multitool))
					src.detecting = !( src.detecting )
					if (src.detecting)
						user.visible_message("\red [user] has reconnected [src]'s detecting unit!", "You have reconnected [src]'s detecting unit.")
					else
						user.visible_message("\red [user] has disconnected [src]'s detecting unit!", "You have disconnected [src]'s detecting unit.")
				else if (istype(W, /obj/item/weapon/wirecutters))
					user.visible_message("\red [user] has cut the wires inside \the [src]!", "You have cut the wires inside \the [src].")
					playsound(src.loc, 'sound/items/Wirecutter.ogg', 50, 1)
					buildstage = 1
					update_icon()
			if(1)
				if(istype(W, /obj/item/stack/cable_coil))
					var/obj/item/stack/cable_coil/C = W
					if (C.use(5))
						user << "<span class='notice'>You wire \the [src].</span>"
						buildstage = 2
						return
					else
						user << "<span class='warning'>You need 5 pieces of cable to do wire \the [src].</span>"
						return
				else if(istype(W, /obj/item/weapon/crowbar))
					user << "You pry out the circuit!"
					playsound(src.loc, 'sound/items/Crowbar.ogg', 50, 1)
					spawn(20)
						var/obj/item/weapon/firealarm_electronics/circuit = new /obj/item/weapon/firealarm_electronics()
						circuit.loc = user.loc
						buildstage = 0
						update_icon()
			if(0)
				if(istype(W, /obj/item/weapon/firealarm_electronics))
					user << "You insert the circuit!"
					qdel(W)
					buildstage = 1
					update_icon()

				else if(istype(W, /obj/item/weapon/wrench))
					user << "You remove the fire alarm assembly from the wall!"
					var/obj/item/firealarm_frame/frame = new /obj/item/firealarm_frame()
					frame.loc = user.loc
					playsound(src.loc, 'sound/items/Ratchet.ogg', 50, 1)
					qdel(src)
		return
	var/area/A = src.loc
	A = A.loc

	if(!A.fire)
		src.alarm()
	else
		src.reset()
	return

/obj/machinery/firealarm/process()//Note: this processing was mostly phased out due to other code, and only runs when needed
	if(stat & (NOPOWER|BROKEN))
		return

	if(src.timing)
		if(src.time > 0)
			src.time = src.time - ((world.timeofday - last_process)/10)
		else
			src.alarm()
			src.time = 0
			src.timing = 0
			processing_objects.Remove(src)
		src.updateDialog()
	last_process = world.timeofday

	if(locate(/obj/fire) in loc)
		alarm()

	return

/obj/machinery/firealarm/power_change()
	..()
	spawn(rand(0,15))
		update_icon()

/obj/machinery/firealarm/attack_hand(mob/user as mob)
	if(user.stat || stat & (NOPOWER|BROKEN))
		return

	if (buildstage != 2)
		return

	user.set_machine(src)
	var/area/A = src.loc
	var/d1
	var/d2
	if (istype(user, /mob/living/carbon/human) || istype(user, /mob/living/silicon))
		A = A.loc

		if (A.fire)
			d1 = text("<A href='?src=\ref[];reset=1'>Reset - Lockdown</A>", src)
		else
			d1 = text("<A href='?src=\ref[];alarm=1'>Alarm - Lockdown</A>", src)
		if (src.timing)
			d2 = text("<A href='?src=\ref[];time=0'>Stop Time Lock</A>", src)
		else
			d2 = text("<A href='?src=\ref[];time=1'>Initiate Time Lock</A>", src)
		var/second = round(src.time) % 60
		var/minute = (round(src.time) - second) / 60
		var/dat = "<HTML><HEAD></HEAD><BODY><TT><B>Fire alarm</B> [d1]\n<HR>The current alert level is: [get_security_level()]</b><br><br>\nTimer System: [d2]<BR>\nTime Left: [(minute ? "[minute]:" : null)][second] <A href='?src=\ref[src];tp=-30'>-</A> <A href='?src=\ref[src];tp=-1'>-</A> <A href='?src=\ref[src];tp=1'>+</A> <A href='?src=\ref[src];tp=30'>+</A>\n</TT></BODY></HTML>"
		user << browse(dat, "window=firealarm")
		onclose(user, "firealarm")
	else
		A = A.loc
		if (A.fire)
			d1 = text("<A href='?src=\ref[];reset=1'>[]</A>", src, stars("Reset - Lockdown"))
		else
			d1 = text("<A href='?src=\ref[];alarm=1'>[]</A>", src, stars("Alarm - Lockdown"))
		if (src.timing)
			d2 = text("<A href='?src=\ref[];time=0'>[]</A>", src, stars("Stop Time Lock"))
		else
			d2 = text("<A href='?src=\ref[];time=1'>[]</A>", src, stars("Initiate Time Lock"))
		var/second = round(src.time) % 60
		var/minute = (round(src.time) - second) / 60
		var/dat = "<HTML><HEAD></HEAD><BODY><TT><B>[stars("Fire alarm")]</B> [d1]\n<HR><b>The current alert level is: [stars(get_security_level())]</b><br><br>\nTimer System: [d2]<BR>\nTime Left: [(minute ? text("[]:", minute) : null)][second] <A href='?src=\ref[src];tp=-30'>-</A> <A href='?src=\ref[src];tp=-1'>-</A> <A href='?src=\ref[src];tp=1'>+</A> <A href='?src=\ref[src];tp=30'>+</A>\n</TT></BODY></HTML>"
		user << browse(dat, "window=firealarm")
		onclose(user, "firealarm")
	return

/obj/machinery/firealarm/Topic(href, href_list)
	..()
	if (usr.stat || stat & (BROKEN|NOPOWER))
		return

	if (buildstage != 2)
		return

	if ((usr.contents.Find(src) || ((get_dist(src, usr) <= 1) && istype(src.loc, /turf))) || (istype(usr, /mob/living/silicon)))
		usr.set_machine(src)
		if (href_list["reset"])
			src.reset()
		else if (href_list["alarm"])
			src.alarm()
		else if (href_list["time"])
			src.timing = text2num(href_list["time"])
			last_process = world.timeofday
			processing_objects.Add(src)
		else if (href_list["tp"])
			var/tp = text2num(href_list["tp"])
			src.time += tp
			src.time = min(max(round(src.time), 0), 120)

		src.updateUsrDialog()

		src.add_fingerprint(usr)
	else
		usr << browse(null, "window=firealarm")
		return
	return

/obj/machinery/firealarm/proc/reset()
	if (!( src.working ))
		return
	var/area/A = src.loc
	A = A.loc
	if (!( istype(A, /area) ))
		return
	A.firereset()
	update_icon()
	return

/obj/machinery/firealarm/proc/alarm()
	if (!( src.working ))
		return
	var/area/A = src.loc
	A = A.loc
	if (!( istype(A, /area) ))
		return
	A.firealert()
	update_icon()
	playsound(src.loc, 'sound/effects/alert.ogg', 75, 0)
	return

/obj/machinery/firealarm/New(loc, dir, building)
	..()

	if(loc)
		src.loc = loc

	if(dir)
		src.set_dir(dir)

	if(building)
		buildstage = 0
		wiresexposed = 1
		pixel_x = (dir & 3)? 0 : (dir == 4 ? -24 : 24)
		pixel_y = (dir & 3)? (dir ==1 ? -24 : 24) : 0

/obj/machinery/firealarm/Destroy()
	//so fire alarms don't keep going forever
	delayed_reset()
	..()

//needed to cancel the alarm after it is deleted
/obj/machinery/firealarm/proc/delayed_reset()
	var/area/A = get_area(src)
	if (!A) return

	src = null
	spawn(600)
		A.firereset()

/obj/machinery/firealarm/initialize()
	if(z in config.alert_levels)
		if(security_level)
			src.overlays += image('icons/obj/monitors.dmi', "overlay_[get_security_level()]")
		else
			src.overlays += image('icons/obj/monitors.dmi', "overlay_green")

	update_icon()

/*
FIRE ALARM CIRCUIT
Just a object used in constructing fire alarms
*/
/obj/item/weapon/firealarm_electronics
	name = "fire alarm electronics"
	icon = 'icons/obj/doors/door_assembly.dmi'
	icon_state = "door_electronics"
	desc = "A circuit. It has a label on it, it says \"Can handle heat levels up to 40 degrees celsius!\""
	w_class = 2.0
	matter = list("metal" = 50, "glass" = 50)


/*
FIRE ALARM ITEM
Handheld fire alarm frame, for placing on walls
Code shamelessly copied from apc_frame
*/
/obj/item/firealarm_frame
	name = "fire alarm frame"
	desc = "Used for building Fire Alarms"
	icon = 'icons/obj/monitors.dmi'
	icon_state = "fire_bitem"
	flags = CONDUCT

/obj/item/firealarm_frame/attackby(obj/item/weapon/W as obj, mob/user as mob)
	if (istype(W, /obj/item/weapon/wrench))
		new /obj/item/stack/sheet/metal( get_turf(src.loc), 2 )
		qdel(src)
		return
	..()

/obj/item/firealarm_frame/proc/try_build(turf/on_wall)
	if (get_dist(on_wall,usr)>1)
		return

	var/ndir = get_dir(on_wall,usr)
	if (!(ndir in cardinal))
		return

	var/turf/loc = get_turf(usr)
	var/area/A = loc.loc
	if (!istype(loc, /turf/simulated/floor))
		usr << "\red Fire Alarm cannot be placed on this spot."
		return
	if (A.requires_power == 0 || A.name == "Space")
		usr << "\red Fire Alarm cannot be placed in this area."
		return

	if(gotwallitem(loc, ndir))
		usr << "\red There's already an item on this wall!"
		return

	new /obj/machinery/firealarm(loc, ndir, 1)

	qdel(src)


/obj/machinery/partyalarm
	name = "\improper PARTY BUTTON"
	desc = "Cuban Pete is in the house!"
	icon = 'icons/obj/monitors.dmi'
	icon_state = "fire0"
	var/detecting = 1.0
	var/working = 1.0
	var/time = 10.0
	var/timing = 0.0
	var/lockdownbyai = 0
	anchored = 1.0
	use_power = 1
	idle_power_usage = 2
	active_power_usage = 6

/obj/machinery/partyalarm/attack_hand(mob/user as mob)
	if(user.stat || stat & (NOPOWER|BROKEN))
		return

	user.machine = src
	var/area/A = get_area(src)
	ASSERT(isarea(A))

	var/d1
	var/d2

	if (istype(user, /mob/living/carbon/human) || istype(user, /mob/living/silicon/ai))

		if (A.party)
			d1 = text("<A href='?src=\ref[];reset=1'>No Party :(</A>", src)
		else
			d1 = text("<A href='?src=\ref[];alarm=1'>PARTY!!!</A>", src)
		if (timing)
			d2 = text("<A href='?src=\ref[];time=0'>Stop Time Lock</A>", src)
		else
			d2 = text("<A href='?src=\ref[];time=1'>Initiate Time Lock</A>", src)
		var/second = time % 60
		var/minute = (time - second) / 60
		var/dat = text("<HTML><HEAD></HEAD><BODY><TT><B>Party Button</B> []\n<HR>\nTimer System: []<BR>\nTime Left: [][] <A href='?src=\ref[];tp=-30'>-</A> <A href='?src=\ref[];tp=-1'>-</A> <A href='?src=\ref[];tp=1'>+</A> <A href='?src=\ref[];tp=30'>+</A>\n</TT></BODY></HTML>", d1, d2, (minute ? text("[]:", minute) : null), second, src, src, src, src)
		user << browse(dat, "window=partyalarm")
		onclose(user, "partyalarm")
	else
		if (A.fire)
			d1 = text("<A href='?src=\ref[];reset=1'>[]</A>", src, stars("No Party :("))
		else
			d1 = text("<A href='?src=\ref[];alarm=1'>[]</A>", src, stars("PARTY!!!"))
		if (timing)
			d2 = text("<A href='?src=\ref[];time=0'>[]</A>", src, stars("Stop Time Lock"))
		else
			d2 = text("<A href='?src=\ref[];time=1'>[]</A>", src, stars("Initiate Time Lock"))
		var/second = time % 60
		var/minute = (time - second) / 60
		var/dat = text("<HTML><HEAD></HEAD><BODY><TT><B>[]</B> []\n<HR>\nTimer System: []<BR>\nTime Left: [][] <A href='?src=\ref[];tp=-30'>-</A> <A href='?src=\ref[];tp=-1'>-</A> <A href='?src=\ref[];tp=1'>+</A> <A href='?src=\ref[];tp=30'>+</A>\n</TT></BODY></HTML>", stars("Party Button"), d1, d2, (minute ? text("[]:", minute) : null), second, src, src, src, src)
		user << browse(dat, "window=partyalarm")
		onclose(user, "partyalarm")
	return

/obj/machinery/partyalarm/proc/reset()
	if (!( working ))
		return
	var/area/A = get_area(src)
	ASSERT(isarea(A))

	A.partyreset()
	return

/obj/machinery/partyalarm/proc/alarm()
	if (!( working ))
		return
	var/area/A = get_area(src)
	ASSERT(isarea(A))

	A.partyalert()
	return

/obj/machinery/partyalarm/Topic(href, href_list)
	..()
	if (usr.stat || stat & (BROKEN|NOPOWER))
		return
	if ((usr.contents.Find(src) || ((get_dist(src, usr) <= 1) && istype(loc, /turf))) || (istype(usr, /mob/living/silicon/ai)))
		usr.machine = src
		if (href_list["reset"])
			reset()
		else
			if (href_list["alarm"])
				alarm()
			else
				if (href_list["time"])
					timing = text2num(href_list["time"])
				else
					if (href_list["tp"])
						var/tp = text2num(href_list["tp"])
						time += tp
						time = min(max(round(time), 0), 120)
		updateUsrDialog()

		add_fingerprint(usr)
	else
		usr << browse(null, "window=partyalarm")
		return
	return