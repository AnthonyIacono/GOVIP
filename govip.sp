/**
 * 00. Includes
 * 01. Globals
 * 02. Forwards
 * 03. Events
 * 04. Functions
 */
 
// 00. Includes
#pragma semicolon 1
#include <sourcemod>
#include <cstrike>
#include <sdktools>
#include <sdktools_functions>
#include <sdkhooks>

// 01. Globals
#define GOVIP_MAINLOOP_INTERVAL 0.1
#define GOVIP_MAXPLAYERS 64
#define GOVIP_PREFIX "[GO:VIP]"
#define GOVIP_INTVECSIZE 6

enum VIPState {
	VIPState_WaitingForMinimumPlayers = 0,
	VIPState_Playing
};

new CurrentVIP = 0;
new LastVIP = 0;
new VIPState:CurrentState = VIPState_WaitingForMinimumPlayers;
new Handle:CVarMinCT = INVALID_HANDLE;
new Handle:CVarMinT = INVALID_HANDLE;
new Handle:CVarVIPWeapon = INVALID_HANDLE;
new Handle:CVarVIPAmmo = INVALID_HANDLE;
new Handle:CVarRescueZone[2];

new Handle:AllRescueZones = INVALID_HANDLE; // Kinda ugly but this contains map entities too.
new bool:RoundComplete = false;
new Handle:hBotMoveTo = INVALID_HANDLE;
new Float:BotIdealRescueZone[3];

// 02. Forwards
public OnPluginStart() {
	CVarMinCT = CreateConVar("govip_min_ct", "2", "Minimum number of CTs to play GOVIP");
	CVarMinT = CreateConVar("govip_min_t", "1", "Minimum number of Ts to play GOVIP");
	CVarVIPWeapon = CreateConVar("govip_weapon", "weapon_p250", "Weapon given to VIP");
	CVarVIPAmmo = CreateConVar("govip_ammo", "12", "Ammo given to VIP");
	CVarRescueZone[0] = CreateConVar("vip_escapezone1", "", "Legacy position for the first rescue zone");
	CVarRescueZone[1] = CreateConVar("vip_escapezone2", "", "Legacy position for the first rescue zone");
	
	RegAdminCmd("sm_govip_readconf", OnReadConf, ADMFLAG_ROOT, "Re-reads known configuration files.");
	
	CurrentState = VIPState_WaitingForMinimumPlayers;
	
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_spawn", Event_PlayerSpawn);
	
	AllRescueZones = CreateArray(GOVIP_INTVECSIZE);
	
	new Handle:hGameConf = LoadGameConfigFile("plugin.govip");
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CCSBotMoveTo");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	hBotMoveTo = EndPrepSDKCall();
	
	RoundComplete = false;
	
	for (new i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i)) {
			continue;
		}
		
		OnClientPutInServer(i);
	}
}

CCSBotMoveTo(bot, Float:origin[3]) {
	SDKCall(hBotMoveTo, bot, origin, 0);
}

public OnClientPutInServer(client) {
	SDKHook(client, SDKHook_WeaponCanUse, OnWeaponCanUse);
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	return true;
}

public OnClientDisconnect(client) {
	if(CurrentState != VIPState_Playing || client != CurrentVIP || RoundComplete) {
		return;
	}
	
	RoundComplete = true;
	
	LastVIP = CurrentVIP;
	
	PrintToChatAll("%s %s", GOVIP_PREFIX, "The VIP has left, round ends in a draw.");
	
	CS_TerminateRound(5.0, CSRoundEnd_Draw);
}

public OnMapStart() {
	CreateTimer(GOVIP_MAINLOOP_INTERVAL, GOVIP_MainLoop, INVALID_HANDLE, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public OnConfigsExecuted()
{
	ProcessConfigurationFiles();
}

// 03. Events
public Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast) {
	RoundComplete = false;
	
	CurrentVIP = GetRandomPlayerOnTeam(CS_TEAM_CT, LastVIP);
	
	if(CurrentState != VIPState_Playing) {
		return;
	}
	
	new arraysize = GetArraySize(AllRescueZones);
	
	if (!arraysize)
	{
		PrintToChatAll("%s %s", GOVIP_PREFIX, "No rescue Zones Found :(");
		return;
	}
	
	new randomZoneIndex = GetRandomInt(0,  - 1);
	decl Float:randomzonearray[GOVIP_INTVECSIZE];
	GetArrayArray(AllRescueZones, randomZoneIndex, randomzonearray, sizeof(randomzonearray));
	
	GetCenterOfTwoPoints(randomzonearray, randomzonearray[3], BotIdealRescueZone);
	
	for (new i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && IsPlayerAlive(i)) {
			new iWeapon = GetPlayerWeaponSlot(i, 4);
			if (iWeapon != -1 && IsValidEdict(iWeapon)) {
				decl String:szClassName[64];
				GetEdictClassname(iWeapon, szClassName, sizeof(szClassName));
				if (StrEqual(szClassName, "weapon_c4", false)) {
					RemovePlayerItem(i, iWeapon);
					AcceptEntityInput(iWeapon, "Kill");
				}
			}
		}
	}
	
	RemoveMapObj();
	
	if(CurrentVIP == 0 || !IsValidPlayer(CurrentVIP)) {
		return;
	}
	
	PrintToChatAll("%s %N %s", GOVIP_PREFIX, CurrentVIP, "is the VIP, CTs protect the VIP from the Terrorists!");
	
	return;
}

public Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast) {
	if(CurrentState != VIPState_Playing) {
		return;
	}
	
	RoundComplete = true; /* The round is 'ogre'. No point in continuing to track stats. */
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast) {
	if(CurrentState != VIPState_Playing) {
		return Plugin_Continue;
	}
	
	new userid = GetEventInt(event, "userid");
	new client = GetClientOfUserId(userid);
	
	if(client != CurrentVIP || RoundComplete) {
		return Plugin_Continue;
	}
	
	RoundComplete = true;
	
	CS_TerminateRound(5.0, CSRoundEnd_TerroristWin);
	
	PrintToChatAll("%s %s", GOVIP_PREFIX, "The VIP has died, Terrorists win!");
	
	LastVIP = CurrentVIP;
	
	return Plugin_Continue;
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast) {
	if(CurrentState != VIPState_Playing) {
		return Plugin_Continue;
	}
	
	new userid = GetEventInt(event, "userid");
	new client = GetClientOfUserId(userid);
	
	if(client != CurrentVIP) {
		return Plugin_Continue;
	}
	
	new String:VIPWeapon[256];
	GetConVarString(CVarVIPWeapon, VIPWeapon, sizeof(VIPWeapon));
	
	StripWeapons(client);
	GivePlayerItem(client, "weapon_knife");
	new index = GivePlayerItem(client, VIPWeapon);
	
	if(index != -1) {
		SetAmmo(client, index, GetConVarInt(CVarVIPAmmo));
	}	
	
	return Plugin_Continue;
}

public Action:OnReadConf(client, argc) {
	if (client && !IsClientInGame(client)){
		return Plugin_Handled;
	}
	
	ReplyToCommand(client, "%s %s", GOVIP_PREFIX, "Rereading the Main configuration files.");
	ProcessConfigurationFiles();
	return Plugin_Handled;
}

SetAmmo(client, weapon, ammo) {
	SetEntProp(client, Prop_Send, "m_iAmmo", ammo, _, GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"));
}

// 04. Functions
public Action:GOVIP_MainLoop(Handle:timer) {
	new CTCount = GetTeamClientCount(CS_TEAM_CT);
	new TCount = GetTeamClientCount(CS_TEAM_T);
	
	if(CurrentState == VIPState_WaitingForMinimumPlayers) {
		if(CTCount >= GetConVarInt(CVarMinCT) && TCount >= GetConVarInt(CVarMinT)) {
			CurrentState = VIPState_Playing;
			PrintToChatAll("%s %s", GOVIP_PREFIX, "Starting the game!");
			return Plugin_Continue;
		}
	}
	else if(CurrentState == VIPState_Playing) {
		if(TCount < GetConVarInt(CVarMinT) || CTCount < GetConVarInt(CVarMinCT)) {
			CurrentState = VIPState_WaitingForMinimumPlayers;
			PrintToChatAll("%s %s", GOVIP_PREFIX, "Game paused, waiting for more players.");
			return Plugin_Continue;
		}
		
		if(CurrentVIP == 0) {
			RoundComplete = true;
			
			CurrentVIP = GetRandomPlayerOnTeam(CS_TEAM_CT, LastVIP);
				
			CS_TerminateRound(5.0, CSRoundEnd_GameStart); 
		}
		else if(!RoundComplete && IsValidPlayer(CurrentVIP)) {
			new Float:vipOrigin[3];
			GetClientAbsOrigin(CurrentVIP, vipOrigin);
			
			if(GetArraySize(AllRescueZones) > 0) {				
				for(new pl = 1; pl < MaxClients; pl++) {
					if(IsValidPlayer(pl) && IsFakeClient(pl)) {
						new Float:plOrigin[3];
						GetClientAbsOrigin(pl, plOrigin);
						if(GetVectorDistance(BotIdealRescueZone, plOrigin) <= 500 && pl != CurrentVIP) {
							continue;
						}
						
						CCSBotMoveTo(pl, BotIdealRescueZone);
					}
				}	
			}
			
			new rescueZoneCount = GetArraySize(AllRescueZones);
			decl Float:rescueZone[GOVIP_INTVECSIZE];
			
			for(new rescueZoneIndex = 0; rescueZoneIndex < rescueZoneCount; rescueZoneIndex++) {
				GetArrayArray(AllRescueZones, rescueZoneIndex, rescueZone, sizeof(rescueZone));
				
				if(IsVectorInsideMinMaxBounds(vipOrigin, rescueZone, rescueZone[(sizeof(rescueZone)/2)])) { // seem good? Yeah, we should throw it into a stock probably,  yeah
					RoundComplete = true;
					
					LastVIP = CurrentVIP;
					
					CS_TerminateRound(5.0, CSRoundEnd_CTWin);
					
					PrintToChatAll("%s %s", GOVIP_PREFIX, "The VIP has been rescued, Counter-Terrorists win.");
					
					break;
				}
			}
		}
	}
	
	return Plugin_Continue;
}

stock bool:IsVectorInsideMinMaxBounds(Float:vec[3], Float:min[], Float:max[]) {
	// min max might be ordered differently than expected, so we have to do a little ternary work here
	new Float:smallerX = min[0] < max[0] ? min[0] : max[0];
	new Float:smallerY = min[1] < max[1] ? min[1] : max[1];
	new Float:smallerZ = min[2] < max[2] ? min[2] : max[2];
	new Float:largerX = min[0] > max[0] ? min[0] : max[0];
	new Float:largerY= min[1] > max[1] ? min[1] : max[1];
	new Float:largerZ = min[2] > max[2] ? min[2] : max[2];

	return vec[0] >= smallerX && vec[1] >= smallerY && vec[2] >= smallerZ &&
		vec[0] <= largerX && vec[1] <= largerY && vec[2] <= largerZ;
}

public Action:OnTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damagetype)
{
	if (!RoundComplete || victim != CurrentVIP || victim == attacker || victim == inflictor) {
		return Plugin_Continue; /* We don't care! */
	}
	
	return Plugin_Handled;
}

public Action:OnWeaponCanUse(client, weapon) {
	if(CurrentState != VIPState_Playing || client != CurrentVIP) {
		return Plugin_Continue;
	}
	
	new String:entityClassName[256];
	
	GetEntityClassname(weapon, entityClassName, sizeof(entityClassName));
	
	new String:VIPWeapon[256];
	GetConVarString(CVarVIPWeapon, VIPWeapon, sizeof(VIPWeapon));
	 
	if(StrEqual(entityClassName, "weapon_knife", false) || StrEqual(entityClassName, VIPWeapon, false)) {
		return Plugin_Continue;
	}
	
	return Plugin_Handled;
}

public Action:Command_JoinTeam(client, const String:command[], argc)  {
	if(CurrentState != VIPState_Playing || client != CurrentVIP) {
		return Plugin_Continue;
	}
	
	PrintToChat(client, "%s %s", GOVIP_PREFIX, "You are not allowed to change teams while you are the VIP.");
	return Plugin_Handled;
}

bool:IsValidPlayer(client) {
	if(!IsValidEntity(client) || !IsClientConnected(client) || !IsClientInGame(client)) {
		return false;
	}
	
	return true;
}

ProcessConfigurationFiles()
{
	new String:buffer[512];
	
	new trigger = -1;

	ClearArray(AllRescueZones);
	decl Float:rescueZone[2][3];
	decl Float:BiggerVector[(sizeof(rescueZone) * sizeof(rescueZone[]))];
	
	while((trigger = FindEntityByClassname(trigger, "trigger_multiple")) != -1) {
		if(GetEntPropString(trigger, Prop_Data, "m_iName", buffer, sizeof(buffer))
			&& StrContains(buffer, "vip_rescue_zone", false) == 0) {
			
			GetEntPropVector(trigger, Prop_Send, "m_WorldMins", rescueZone[0]);
			GetEntPropVector(trigger, Prop_Send, "m_WorldMaxs", rescueZone[1]);
			
			AddVectorsToLargerVector(rescueZone[0], rescueZone[1], BiggerVector);
			
			PushArrayArray(AllRescueZones, BiggerVector); /* Bot Support */
			
			SDKHook(trigger, SDKHook_Touch, TouchRescueZone);
		}
	}
	
	decl String:coords[GOVIP_INTVECSIZE][128];
	decl Float:toarray[sizeof(coords)];
	for(new x = 0; x < sizeof(CVarRescueZone); x++) {
		GetConVarString(CVarRescueZone[x], buffer, sizeof(buffer));
		
		TrimString(buffer);
		
		if(buffer[0] == '\0' || StrEqual(buffer, "") || StrEqual(buffer, "0") || StrEqual(buffer, "false", false) || StrEqual(buffer, "off", false)) {
			continue;
		}
		
		ExplodeString(buffer, " ", coords, sizeof(coords), sizeof(coords[]));
		
		for (new i; i < sizeof(coords); i++)
		{
			toarray[i] = StringToFloat(coords[i]);
		}
		
		PushArrayArray(AllRescueZones, toarray, sizeof(toarray));
		
		PrintToServer("%s Loading legacy rescue zone beginning at [%s, %s, %s], ending at [%s, %s, %s].", GOVIP_PREFIX, coords[0], coords[1], coords[2], coords[3], coords[4], coords[5]);
	}
		
	if (!GetCurrentMap(buffer, sizeof(buffer)))
	{
		return; /* Should never happen... We should maybe even throw an error. */
	}
	
	new Handle:kv = CreateKeyValues("RescueZones");
	
	decl String:path[1024];
	BuildPath(Path_SM, path, sizeof(path), "configs/rescue_zones.cfg");
	
	FileToKeyValues(kv, path);
	
	if(KvJumpToKey(kv, buffer)) {
		KvGotoFirstSubKey(kv);
		decl String:endcoords[(sizeof(coords)/2)][sizeof(coords[])];
		do {
			KvGetString(kv, "start", buffer, sizeof(buffer));
			
			ExplodeString(buffer, " ", coords, sizeof(coords), sizeof(coords[]));
			
			KvGetString(kv, "end", buffer, sizeof(buffer));
			ExplodeString(buffer, " ", endcoords, sizeof(endcoords), sizeof(endcoords[]));

			PrintToServer("%s Loading rescue zone beginning at [%s, %s, %s], ending at [%s, %s, %s].", GOVIP_PREFIX, coords[0], coords[1], coords[2], endcoords[0], endcoords[1], endcoords[2]);
			
			for (new i; i < sizeof(endcoords); i++)
			{
				toarray[i] = StringToFloat(coords[i]);
			}
			
			for (new i = 3; i < sizeof(coords); i++)
			{
				toarray[i] = StringToFloat(endcoords[(i - 3)]);
			}
			
			PushArrayArray(AllRescueZones, toarray, sizeof(toarray)); // for the bots
		} while (KvGotoNextKey(kv));
	}	
	
	CloseHandle(kv);
}

GetRandomPlayerOnTeam(team, ignore = 0) {
	new teamClientCount = GetTeamClientCount(team);
	
	if(teamClientCount <= 0) {
		return 0;
	}
	
	new client;
	
	do {
		client = GetRandomInt(1, MaxClients);
	} while((teamClientCount > 1 && client == ignore) || !IsClientInGame(client) || GetClientTeam(client) != team);
	
	return client;
}

stock RemoveMapObj() {
	decl String:Class[65];
	new maxent = GetEntityCount();	/* This isn't what you think it is.
									* This function will return the highest edict index in use on the server,
									* not the true number of active entities.
									*/
								
	for (new i=MaxClients;i<maxent;i++) {
		if(!IsValidEdict(i) || !IsValidEntity(i)) {
			continue;
		}
		
		if(GetEdictClassname(i, Class, sizeof(Class)) \
			&& StrContains("func_bomb_target_hostage_entity_func_hostage_rescue",Class) != -1) {
			AcceptEntityInput(i, "Kill");
		}
	}
}

StripWeapons(client) {
	new weaponID;
	
	for(new x = CS_SLOT_PRIMARY; x <= CS_SLOT_C4; x++) {
		while ((weaponID = GetPlayerWeaponSlot(client, x)) != -1) {
			RemovePlayerItem(client, weaponID);
			AcceptEntityInput(weaponID, "Kill");
		}
	}
}

GetCenterOfTwoPoints(const Float:first[], const Float:second[], Float:center[3]) {
	center[0] = (first[0] + second[0]) / 2;
	center[1] = (first[1] + second[1]) / 2;
	center[2] = (first[2] + second[2]) / 2;
}

AddVectorsToLargerVector(const Float:first[3], const Float:second[3], Float:bigger[GOVIP_INTVECSIZE])
{
	bigger[0] = first[0];
	bigger[1] = first[1];
	bigger[2] = first[2];
	bigger[3] = second[0];
	bigger[4] = second[1];
	bigger[5] = second[2];
}

public TouchRescueZone(trigger, client) {
	if(!IsValidPlayer(client)) {
		return;
	}
	
	if(CurrentState != VIPState_Playing || client != CurrentVIP || RoundComplete) {
		return;
	}
	
	RoundComplete = true;
	
	CS_TerminateRound(5.0, CSRoundEnd_CTWin);
	
	LastVIP = CurrentVIP;
	
	PrintToChatAll("%s %s", GOVIP_PREFIX, "The VIP has been rescued, Counter-Terrorists win.");
}