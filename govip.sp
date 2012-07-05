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

enum BOTState {
	BOTState_NotDirected = 0,
	BOTState_Directed
};

new g_iCurrentVIP = 0;
new g_iLastVIP = 0;
new VIPState:g_iCurrentState = VIPState_WaitingForMinimumPlayers;
new BOTState:g_iBotDirectionState = BOTState_NotDirected;
new Handle:g_hCVarMinCT = INVALID_HANDLE;
new Handle:g_hCVarMinT = INVALID_HANDLE;
new Handle:g_hCVarVIPWeapon = INVALID_HANDLE;
new Handle:g_hCVarVIPWeaponSuccess = INVALID_HANDLE;
new Handle:g_hCVarVIPAmmo = INVALID_HANDLE;
new Handle:g_hCVarRescueZone[2];

new Handle:g_hAllRescueZones = INVALID_HANDLE; // Kinda ugly but this contains map entities too.
new bool:g_bRoundComplete = false;
new g_iRoundWonByTeam = 0;
new Handle:g_hBotMoveTo = INVALID_HANDLE;
new Float:g_fBotIdealRescueZone[3];

// 02. Forwards
public OnPluginStart() {
	g_hCVarMinCT = CreateConVar("govip_min_ct", "2", "Minimum number of CTs to play GOVIP");
	g_hCVarMinT = CreateConVar("govip_min_t", "1", "Minimum number of Ts to play GOVIP");
	g_hCVarVIPWeapon = CreateConVar("govip_weapon", "weapon_p250", "Weapon given to VIP");
	g_hCVarVIPWeaponSuccess = CreateConVar("govip_weapon_success", "weapon_ak47", "Weapon given to VIP on Escaping/Living.");
	g_hCVarVIPAmmo = CreateConVar("govip_ammo", "12", "Ammo given to VIP");
	g_hCVarRescueZone[0] = CreateConVar("vip_escapezone1", "", "Legacy position for the first rescue zone");
	g_hCVarRescueZone[1] = CreateConVar("vip_escapezone2", "", "Legacy position for the first rescue zone");
	
	RegAdminCmd("sm_govip_readconf", OnReadConf, ADMFLAG_ROOT, "Re-reads known configuration files.");
	
	g_iCurrentState = VIPState_WaitingForMinimumPlayers;
	
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_freeze_end", Event_RoundFreezeEnd, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath);
	//HookEvent("player_spawn", Event_PlayerSpawn);
	
	g_hAllRescueZones = CreateArray(GOVIP_INTVECSIZE);
	
	new Handle:hGameConf = LoadGameConfigFile("plugin.govip");
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CCSBotMoveTo");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hBotMoveTo = EndPrepSDKCall();
	
	g_bRoundComplete = false;
	
	for (new i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i)) {
			continue;
		}
		
		OnClientPutInServer(i);
	}
}

CCSBotMoveTo(bot, Float:origin[3]) {
	SDKCall(g_hBotMoveTo, bot, origin, 0);
}

public OnClientPutInServer(client) {
	SDKHook(client, SDKHook_WeaponCanUse, OnWeaponCanUse);
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	return true;
}

public OnClientDisconnect(client) {
	if (g_iCurrentState != VIPState_Playing || client != g_iCurrentVIP || g_bRoundComplete) {
		return;
	}
	
	g_bRoundComplete = true;
	
	g_iLastVIP = g_iCurrentVIP;
	
	PrintToChatAll("%s %s", GOVIP_PREFIX, "The VIP has left, round ends in a draw.");
	g_iBotDirectionState = BOTState_NotDirected;
	
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
	g_bRoundComplete = false;
	
	g_iCurrentVIP = GetRandomPlayerOnTeam(CS_TEAM_CT, g_iLastVIP);
	
	SetupVIP(g_iCurrentVIP);
	
	if (g_iLastVIP && g_iLastVIP != g_iCurrentVIP && g_iRoundWonByTeam == CS_TEAM_CT) {
		if (IsClientInGame(g_iLastVIP) && GetClientTeam(g_iLastVIP) == CS_TEAM_CT) {
			SetupVIP(g_iLastVIP);
			
			decl String:weaponName[96];
			GetConVarString(g_hCVarVIPWeaponSuccess, weaponName, sizeof(weaponName));
			TrimString(weaponName);
			
			if (weaponName[0] != '\0') {
				GivePlayerItem(g_iLastVIP, weaponName);
			}
		}
	}
	
	if (g_iCurrentState != VIPState_Playing) {
		return;
	}
	
	new arraysize = GetArraySize(g_hAllRescueZones);
	
	if (!arraysize) {
		PrintToChatAll("%s %s", GOVIP_PREFIX, "No rescue Zones Found :(");
		return;
	}
	
	new randomZoneIndex = GetRandomInt(0, arraysize - 1);
	decl Float:randomzonearray[GOVIP_INTVECSIZE];
	GetArrayArray(g_hAllRescueZones, randomZoneIndex, randomzonearray, sizeof(randomzonearray));
	
	GetCenterOfTwoPoints(randomzonearray, randomzonearray[3], g_fBotIdealRescueZone);
	
	for (new i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || !IsPlayerAlive(i)) {
			continue;
		}
		
		new iWeapon = GetPlayerWeaponSlot(i, 4);
		if (iWeapon == -1 || !IsValidEdict(iWeapon)) {
			continue;
		}
		
		decl String:szClassName[64];
		if (GetEdictClassname(iWeapon, szClassName, sizeof(szClassName)) && StrEqual(szClassName, "weapon_c4", false)) {
			RemovePlayerItem(i, iWeapon);
			AcceptEntityInput(iWeapon, "Kill");
		}
	}
	
	RemoveMapObj();
	
	if (g_iCurrentVIP == 0 || !IsValidPlayer(g_iCurrentVIP)) {
		return;
	}
	
	PrintToChatAll("%s %N %s", GOVIP_PREFIX, g_iCurrentVIP, "is the VIP, CTs protect the VIP from the Terrorists!");
	
	return;
}

public Event_RoundFreezeEnd(Handle:event, const String:name[], bool:dontBroadcast) {
	g_iBotDirectionState = BOTState_Directed;
}

public Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast) {
	if (g_iCurrentState != VIPState_Playing) {
		return;
	}
	
	g_iLastVIP = g_iCurrentVIP;
	g_iRoundWonByTeam = GetEventInt(event, "winner");
	
	g_bRoundComplete = true; /* The round is 'ogre'. No point in continuing to track stats. */
	g_iBotDirectionState = BOTState_NotDirected;
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast) {
	if (g_iCurrentState != VIPState_Playing) {
		return Plugin_Continue;
	}
	
	new userid = GetEventInt(event, "userid");
	new client = GetClientOfUserId(userid);
	
	if (client != g_iCurrentVIP || g_bRoundComplete) {
		return Plugin_Continue;
	}
	
	g_bRoundComplete = true;
	
	CS_TerminateRound(5.0, CSRoundEnd_TerroristWin);
	
	PrintToChatAll("%s %s", GOVIP_PREFIX, "The VIP has died, Terrorists win!");
	
	g_iLastVIP = g_iCurrentVIP;
	g_iRoundWonByTeam = CS_TEAM_T;
	
	g_iBotDirectionState = BOTState_NotDirected;
	return Plugin_Continue;
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast) {
	if (g_iCurrentState != VIPState_Playing) {
		return Plugin_Continue;
	}
	
	new userid = GetEventInt(event, "userid");
	new client = GetClientOfUserId(userid);
	
	if (client != g_iCurrentVIP) {
		return Plugin_Continue;
	}
	

	
	return Plugin_Continue;
}

public Action:OnReadConf(client, argc) {
	if (client && !IsClientInGame(client)) {
		return Plugin_Handled;
	}
	
	ReplyToCommand(client, "%s %s", GOVIP_PREFIX, "Rereading the Main configuration files.");
	ProcessConfigurationFiles();
	return Plugin_Handled;
}

SetupVIP(client)
{
	decl String:VIPWeapon[64];
	GetConVarString(g_hCVarVIPWeapon, VIPWeapon, sizeof(VIPWeapon));
	
	StripWeapons(client);
	GivePlayerItem(client, "weapon_knife");
	new index = GivePlayerItem(client, VIPWeapon);
	
	if (index != -1) {
		SetAmmo(client, index, GetConVarInt(g_hCVarVIPAmmo));
	}
}

SetAmmo(client, weapon, ammo) {
	SetEntProp(client, Prop_Send, "m_iAmmo", ammo, _, GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"));
}

// 04. Functions
public Action:GOVIP_MainLoop(Handle:timer) {
	new CTCount = GetTeamClientCount(CS_TEAM_CT);
	new TCount = GetTeamClientCount(CS_TEAM_T);
	
	if (g_iCurrentState == VIPState_WaitingForMinimumPlayers) {
		if (CTCount >= GetConVarInt(g_hCVarMinCT) && TCount >= GetConVarInt(g_hCVarMinT)) {
			g_iCurrentState = VIPState_Playing;
			PrintToChatAll("%s %s", GOVIP_PREFIX, "Starting the game!");
			return Plugin_Continue;
		}
	}
	else if (g_iCurrentState == VIPState_Playing) {
		if (TCount < GetConVarInt(g_hCVarMinT) || CTCount < GetConVarInt(g_hCVarMinCT)) {
			g_iCurrentState = VIPState_WaitingForMinimumPlayers;
			PrintToChatAll("%s %s", GOVIP_PREFIX, "Game paused, waiting for more players.");
			return Plugin_Continue;
		}
		
		if (g_iCurrentVIP == 0) {
			g_bRoundComplete = true;
			
			g_iCurrentVIP = GetRandomPlayerOnTeam(CS_TEAM_CT, g_iLastVIP);
				
			CS_TerminateRound(5.0, CSRoundEnd_GameStart); 
		}
		else if (!g_bRoundComplete && IsValidPlayer(g_iCurrentVIP)) {
			new Float:vipOrigin[3];
			GetClientAbsOrigin(g_iCurrentVIP, vipOrigin);
			
			if (g_iBotDirectionState == BOTState_Directed && GetArraySize(g_hAllRescueZones) > 0) {
				decl Float:plOrigin[3];
				for (new pl = 1; pl <= MaxClients; pl++) {
					if (!IsValidPlayer(pl) || !IsFakeClient(pl)) {
						continue;
					}
					
					GetClientAbsOrigin(pl, plOrigin);
					if (pl != g_iCurrentVIP && GetVectorDistance(g_fBotIdealRescueZone, plOrigin) <= 500) {
						continue;
					}
					
					CCSBotMoveTo(pl, g_fBotIdealRescueZone);
				}	
			}
			
			new rescueZoneCount = GetArraySize(g_hAllRescueZones);
			decl Float:rescueZone[GOVIP_INTVECSIZE];
			
			for (new rescueZoneIndex = 0; rescueZoneIndex < rescueZoneCount; rescueZoneIndex++) {
				GetArrayArray(g_hAllRescueZones, rescueZoneIndex, rescueZone, sizeof(rescueZone));
				
				if (IsVectorInsideMinMaxBounds(vipOrigin, rescueZone, rescueZone[(sizeof(rescueZone)/2)])) { // seem good? Yeah, we should throw it into a stock probably,  yeah
					g_bRoundComplete = true;
					
					g_iLastVIP = g_iCurrentVIP;
					
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

public Action:CS_OnBuyCommand(client, const String:weapon[])
{
	if (client != g_iCurrentVIP || !IsClientInGame(client)) {
		return Plugin_Continue;
	}
	
	if (IsFakeClient(client)) {
		return Plugin_Handled;
	}
	
	PrintToChat(client, "%s %s", GOVIP_PREFIX, "The VIP is unable to buy weapons.");
	return Plugin_Handled;
}

public Action:OnTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damagetype)
{
	if (!g_bRoundComplete || victim != g_iCurrentVIP || victim == attacker || victim == inflictor) {
		return Plugin_Continue; /* We don't care! */
	}
	
	return Plugin_Handled;
}

public Action:OnWeaponCanUse(client, weapon) {
	if (g_iCurrentState != VIPState_Playing || client != g_iCurrentVIP) {
		return Plugin_Continue;
	}
	
	new String:entityClassName[256];
	
	GetEntityClassname(weapon, entityClassName, sizeof(entityClassName));
	
	new String:VIPWeapon[256];
	GetConVarString(g_hCVarVIPWeapon, VIPWeapon, sizeof(VIPWeapon));
	
	if (StrEqual(entityClassName, "weapon_knife", false) || StrEqual(entityClassName, VIPWeapon, false)) {
		return Plugin_Continue;
	}
	
	return Plugin_Handled;
}

public Action:Command_JoinTeam(client, const String:command[], argc) {
	if (g_iCurrentState != VIPState_Playing || client != g_iCurrentVIP) {
		return Plugin_Continue;
	}
	
	PrintToChat(client, "%s %s", GOVIP_PREFIX, "You are not allowed to change teams while you are the VIP.");
	return Plugin_Handled;
}

bool:IsValidPlayer(client) {
	if (!IsValidEntity(client) || !IsClientConnected(client) || !IsClientInGame(client)) {
		return false;
	}
	
	return true;
}

ProcessConfigurationFiles()
{
	new String:buffer[512];
	
	new trigger = -1;

	ClearArray(g_hAllRescueZones);
	decl String:coords[GOVIP_INTVECSIZE][128];
	decl Float:toarray[sizeof(coords)];
	
	decl Float:rescueOrigin[3];
	decl Float:rescueTemp[2][3];
	
	while ((trigger = FindEntityByClassname(trigger, "trigger_multiple")) != -1) {
		if (GetEntPropString(trigger, Prop_Data, "m_iName", buffer, sizeof(buffer))
			&& StrContains(buffer, "vip_rescue_zone", false) == 0) {
			GetEntPropVector(trigger, Prop_Send, "m_vecOrigin", rescueOrigin);
			GetEntPropVector(trigger, Prop_Send, "m_vecMins", rescueTemp[0]);
			GetEntPropVector(trigger, Prop_Send, "m_vecMaxs", rescueTemp[1]);
			
			PrintToServer("Mins: %f %f %f Maxs: %f %f %f", rescueTemp[0][0], rescueTemp[0][1], rescueTemp[0][2], rescueTemp[1][0], rescueTemp[1][1], rescueTemp[1][2]);
			
			AddVectors(rescueOrigin, rescueTemp[0], rescueTemp[0]);
			AddVectors(rescueOrigin, rescueTemp[0], rescueTemp[1]);
			
			AddVectorsToLargerVector(rescueTemp[0], rescueTemp[1], toarray);
			
			PushArrayArray(g_hAllRescueZones, toarray, sizeof(toarray)); /* Bot Support */
			PrintToServer("%s Hooking New rescue zone beginning at [%f, %f, %f], ending at [%f, %f, %f]", GOVIP_PREFIX, toarray[0], toarray[1], toarray[2], toarray[3], toarray[4], toarray[5]);
			SDKHook(trigger, SDKHook_Touch, TouchRescueZone);
		}
	}
	
	for (new x = 0; x < sizeof(g_hCVarRescueZone); x++) {
		GetConVarString(g_hCVarRescueZone[x], buffer, sizeof(buffer));
		
		TrimString(buffer);
		
		if (buffer[0] == '\0' || StrEqual(buffer, "") || StrEqual(buffer, "0") || StrEqual(buffer, "false", false) || StrEqual(buffer, "off", false)) {
			continue;
		}
		
		ExplodeString(buffer, " ", coords, sizeof(coords), sizeof(coords[]));
		
		for (new i; i < sizeof(coords); i++) {
			toarray[i] = StringToFloat(coords[i]);
		}
		
		PushArrayArray(g_hAllRescueZones, toarray, sizeof(toarray));
		
		PrintToServer("%s Loading legacy rescue zone beginning at [%s, %s, %s], ending at [%s, %s, %s].", GOVIP_PREFIX, coords[0], coords[1], coords[2], coords[3], coords[4], coords[5]);
	}
		
	if (!GetCurrentMap(buffer, sizeof(buffer))) {
		return; /* Should never happen... We should maybe even throw an error. */
	}
	
	new Handle:kv = CreateKeyValues("RescueZones");
	
	decl String:path[1024];
	BuildPath(Path_SM, path, sizeof(path), "configs/rescue_zones.cfg");
	
	if (!FileToKeyValues(kv, path)) {
		PrintToServer("%s %s", GOVIP_PREFIX, "Unable to parse file: %s", path);
		return;
	}
	
	if (KvJumpToKey(kv, buffer)) {
		KvGotoFirstSubKey(kv);
		decl String:endcoords[(sizeof(coords)/2)][sizeof(coords[])];
		do {
			KvGetString(kv, "start", buffer, sizeof(buffer));
			
			if (ExplodeString(buffer, " ", coords, sizeof(coords), sizeof(coords[])) != 3)
			{
				PrintToServer("%s %s %s", GOVIP_PREFIX, "Illegal Input for field Start: ", buffer);
				continue;
			}
			
			KvGetString(kv, "end", buffer, sizeof(buffer));
			if (ExplodeString(buffer, " ", endcoords, sizeof(endcoords), sizeof(endcoords[])) != 3)
			{
				PrintToServer("%s %s %s", GOVIP_PREFIX, "Illegal Input for field End: ", buffer);
				continue;
			}

			PrintToServer("%s Loading rescue zone beginning at [%s, %s, %s], ending at [%s, %s, %s].", GOVIP_PREFIX, coords[0], coords[1], coords[2], endcoords[0], endcoords[1], endcoords[2]);
			
			for (new i; i < sizeof(endcoords); i++) {
				toarray[i] = StringToFloat(coords[i]);
			}
			
			for (new i = 3; i < sizeof(coords); i++) {
				toarray[i] = StringToFloat(endcoords[(i - 3)]);
			}
			
			PushArrayArray(g_hAllRescueZones, toarray, sizeof(toarray)); // for the bots
		} while (KvGotoNextKey(kv));
	}	
	
	CloseHandle(kv);
}

GetRandomPlayerOnTeam(team, ignore = 0) {
	new teamClientCount = GetTeamClientCount(team);
	
	if (teamClientCount <= 0) {
		return 0;
	}
	
	new client;
	
	do {
		client = GetRandomInt(1, MaxClients);
	} while ((teamClientCount > 1 && client == ignore) || !IsClientInGame(client) || GetClientTeam(client) != team);
	
	return client;
}

stock RemoveMapObj() {
	decl String:Class[65];
	new maxent = GetEntityCount();	/* This isn't what you think it is.
									* This function will return the highest edict index in use on the server,
									* not the true number of active entities.
									*/
								
	for (new i=MaxClients;i<=maxent;i++) {
		if (!IsValidEdict(i) || !IsValidEntity(i)) {
			continue;
		}
		
		if (GetEdictClassname(i, Class, sizeof(Class))
			&& StrContains("func_bomb_target_hostage_entity_func_hostage_rescue",Class) != -1) {
			AcceptEntityInput(i, "Kill");
		}
	}
}

StripWeapons(client) {
	new weaponID;
	
	for (new x = CS_SLOT_PRIMARY; x <= CS_SLOT_C4; x++) {
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

AddVectorsToLargerVector(const Float:min[3], const Float:max[3], Float:bigger[GOVIP_INTVECSIZE])
{
	bigger[0] = min[0] < max[0] ? min[0] : max[0];
	bigger[1] = min[1] < max[1] ? min[1] : max[1];
	bigger[2] = min[2] < max[2] ? min[2] : max[2];
	bigger[3] = min[0] > max[0] ? min[0] : max[0];
	bigger[4] = min[1] > max[1] ? min[1] : max[1];
	bigger[5] = min[2] > max[2] ? min[2] : max[2];
}

public TouchRescueZone(trigger, client) {
	if (!IsValidPlayer(client)) {
		return;
	}
	
	if (g_iCurrentState != VIPState_Playing || client != g_iCurrentVIP || g_bRoundComplete) {
		return;
	}
	
	g_bRoundComplete = true;
	
	CS_TerminateRound(5.0, CSRoundEnd_CTWin);
	
	g_iLastVIP = g_iCurrentVIP;
	g_iBotDirectionState = BOTState_NotDirected;
	g_iRoundWonByTeam = CS_TEAM_CT;
	PrintToChatAll("%s %s", GOVIP_PREFIX, "The VIP has been rescued, Counter-Terrorists win.");
}