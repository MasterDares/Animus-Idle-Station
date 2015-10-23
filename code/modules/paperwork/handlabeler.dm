/obj/item/weapon/hand_labeler
	name = "hand labeler"
	icon = 'icons/obj/bureaucracy.dmi'
	icon_state = "labeler0"
	item_state = "flight"
	var/label = null
	var/labels_left = 30
	var/mode = 0	//off or on.

/obj/item/weapon/hand_labeler/attack()
	return

/obj/item/weapon/hand_labeler/attackby(obj/item/I as obj, mob/user as mob)
	if (istype(I, /obj/item/weapon/paper))
		if (labels_left < 30)
			labels_left = min(labels_left+10, 30)
			user << "<span class='notice'>You add some labels to the [src.name].</span>"
			qdel(I)
		else
			user << "<span class='notice'>The [src] is full! You can't add any more labels to it.</span>"

	return

/obj/item/weapon/hand_labeler/afterattack(atom/A, mob/user as mob, proximity)
	if(!proximity)
		return
	if(!mode)	//if it's off, give up.
		return
	if(A == loc)	// if placing the labeller into something (e.g. backpack)
		return		// don't set a label

	if(!labels_left)
		user << "<span class='notice'>No labels left.</span>"
		return
	if(!label || !length(label))
		user << "<span class='notice'>No text set.</span>"
		return
	if(length(A.name) + length(label) > 64)
		user << "<span class='notice'>Label too big.</span>"
		return
	if(ishuman(A))
		user << "<span class='notice'>The label refuses to stick to [A.name].</span>"
		return
	if(issilicon(A))
		user << "<span class='notice'>The label refuses to stick to [A.name].</span>"
		return
	if(isobserver(A))
		user << "<span class='notice'>[src] passes through [A.name].</span>"
		return
	if(istype(A, /obj/item/weapon/reagent_containers/glass) || istype(A, /obj/item/weapon/virusdish))
		user << "<span class='notice'>The label can't stick to the [A.name].  (Try using a pen)</span>"
		return

	user.visible_message("<span class='notice'>[user] labels [A] as [label].</span>", \
						 "<span class='notice'>You label [A] as [label].</span>")
	A.name = "[A.name] ([label])"
	labels_left -= 1

/obj/item/weapon/hand_labeler/attack_self(mob/user as mob)
	mode = !mode
	icon_state = "labeler[mode]"
	if(mode)
		user << "<span class='notice'>You turn on \the [src].</span>"
		//Now let them chose the text.
		var/str = copytext(reject_bad_text(input(user,"Label text?","Set label","")),1,MAX_NAME_LEN)
		if(!str || !length(str))
			user << "<span class='notice'>Invalid text.</span>"
			return
		label = str
		user << "<span class='notice'>You set the text to '[str]'.</span>"
	else
		user << "<span class='notice'>You turn off \the [src].</span>"