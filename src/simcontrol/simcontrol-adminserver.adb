-------------------------------------------------------------------------------
--   Copyright 2012 Julian Schutsch
--
--   This file is part of ParallelSim
--
--   ParallelSim is free software: you can redistribute it and/or modify
--   it under the terms of the GNU Affero General Public License as published
--   by the Free Software Foundation, either version 3 of the License, or
--   (at your option) any later version.
--
--   ParallelSim is distributed in the hope that it will be useful,
--   but WITHOUT ANY WARRANTY; without even the implied warranty of
--   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--   GNU Affero General Public License for more details.
--
--   You should have received a copy of the GNU Affero General Public License
--   along with ParallelSim.  If not, see <http://www.gnu.org/licenses/>.
-------------------------------------------------------------------------------

pragma Ada_2005;

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Text_IO.Unbounded_IO; use Ada.Text_IO.Unbounded_IO;
with Ada.Integer_Text_IO; use Ada.Integer_Text_IO;

with Network.Streams;
with Endianess;
with Ada.Streams;
with Types;
with SimCommon;
with AdminProtocol;
with Logging;

package body SimControl.AdminServer is

   type ReceiveStatus_Enum is
     (ReceiveStatusWaitForIdentification,
      ReceiveStatusSend,
      ReceiveStatusWaitForCommand,
      ReceiveStatusProcessCommand);

   type SendStatus_Enum is
     (SendStatusReceive,
      SendStatusIdentify,
      SendStatusReady);
   ---------------------------------------------------------------------------

   type ServerChannelCallBack_Type is
     new Network.Streams.ChannelCallBack_Type with
      record
         ReceiveStatus : ReceiveStatus_Enum;
         SendStatus    : SendStatus_Enum;
         Channel       : Network.Streams.Channel_ClassAccess;
      end record;

   type ServerChannelCallBack_Access is access ServerChannelCallBack_Type;

   overriding
   procedure OnCanSend
     (Item : in out ServerChannelCallBack_Type);

   overriding
   procedure OnReceive
     (Item : in out ServerChannelCallBack_Type);

   overriding
   procedure OnDisconnect
     (Item : in out ServerChannelCallBack_Type);
   ---------------------------------------------------------------------------

   type ServerCallBack_Type is
     new Network.Streams.ServerCallBack_Type with null record;

   overriding
   procedure OnAccept
     (Item    : in out ServerCallBack_Type;
      Channel : Network.Streams.Channel_ClassAccess);
   ---------------------------------------------------------------------------

   StreamImplementation : Network.Streams.Implementation_Type;
   Server               : Network.Streams.Server_ClassAccess;
   ServerCallBack       : aliased ServercallBack_Type;
   CurrentCommand       : Types.Integer32;
   LogImplementation    : Logging.Implementation_Type;
   LogContext           : Logging.Context_ClassAccess;
   LogMainChannel       : Logging.Channel_ClassAccess;
   ---------------------------------------------------------------------------

   function Cmd_AdminServerMessage
     (Item : in ServerChannelCallBack_Type)
      return Boolean is

      Message : Unbounded_String;

   begin
      Unbounded_String'Read
        (Item.Channel,
         Message);
      Put(Message);
      New_Line;
      return True;
   end Cmd_AdminServerMessage;
   ---------------------------------------------------------------------------

   type CmdArray is array (AdminProtocol.ServerCmd_NativeType range <>) of
     access function
       (Item : in ServerChannelCallBack_Type) return Boolean;

   Cmds:constant CmdArray:=
     (AdminProtocol.ServerCmdMessage=>Cmd_AdminServerMessage'Access);

   DebugOnce : Boolean:=False;

   procedure OnReceive
     (Item : in out ServerChannelCallBack_Type) is

      use type SimCommon.NetworkIDString;

      PrevPosition : Ada.Streams.Stream_Element_Offset;

   begin
      Put("OnReceive");
      loop
         PrevPosition:=Item.Channel.ReceivePosition;
         case Item.ReceiveStatus is
            when ReceiveStatusWaitForIdentification =>
               declare
                  Identity : SimCommon.NetworkIDString;
               begin
                  SimCommon.NetworkIDString'Read
                    (Item.Channel,
                     Identity);
                  if Identity/=SimCommon.NetworkAdminClientID then
                     Put("Wrong identification of the client for Network Admin");
                     -- TODO: Kill channel
                     return;
                  end if;
                  Item.ReceiveStatus := ReceiveStatusSend;
                  Item.SendStatus    := SendStatusIdentify;
                  return;
               end;
            when ReceiveStatusSend =>
               raise ServerStatusError;
            when ReceiveStatusWaitForCommand =>
               declare
                  Command : AdminProtocol.ServerCmd_NetworkType;
               begin
                  if not DebugOnce then
                     Network.Streams.DebugReceive
                       (Stream => Item.Channel.all);
                     DebugOnce:=true;
                  end if;
                  Put("Get COmmand");
                  Put(Integer(Item.Channel.ReceivePosition));
                  AdminProtocol.ServerCmd_NetworkType'Read
                    (Item.Channel,
                     Command);
                  CurrentCommand:=Endianess.From(Command);
                  Put("Command Receive");
                  Put(Integer(CurrentCommand));
                  if CurrentCommand not in Cmds'Range then
                     Put("Invalid Command");
                     return;
                  end if;
                  New_Line;
                  Item.ReceiveStatus:=ReceiveStatusProcessCommand;
                  Put("Done Get Command");
                  New_Line;
               end;
            when ReceiveStatusProcessCommand =>
               Put("Process Command");
               if Cmds(CurrentCommand).all
                 (Item=> Item) then
                  Item.ReceiveStatus:=ReceiveStatusWaitForCommand;
               end if;
               Put(" ProcessDone");
               New_Line;
         end case;
      end loop;
   exception
      when Network.Streams.StreamOverflow =>
         Item.Channel.ReceivePosition := PrevPosition;
   end OnReceive;
   ---------------------------------------------------------------------------

   procedure OnCanSend
     (Item : in out ServerChannelCallBack_Type) is

      PrevPosition : Ada.Streams.Stream_Element_Offset;

   begin
      loop
         PrevPosition:=Item.Channel.WritePosition;
         case Item.SendStatus is
            when SendStatusReceive =>
               return;
            when SendStatusIdentify =>
               Put("send Admin ServerID");
               New_Line;
               SimCommon.NetworkIDString'Write
                 (Item.Channel,
                  SimCommon.NetworkAdminServerID);
               Item.ReceiveStatus := ReceiveStatusWaitForCommand;
               Item.SendStatus    := SendStatusReady;
               return;
            when SendStatusReady =>
               return;
         end case;
      end loop;
   exception
      when Network.Streams.StreamOverflow =>
         Item.Channel.WritePosition:=PrevPosition;
   end OnCanSend;
   ---------------------------------------------------------------------------

   procedure OnDisconnect
     (Item : in out ServerChannelCallBack_Type) is
      pragma Warnings(Off,Item);
   begin
      Put("Disconnect for Admin interface");
      New_Line;
      Network.Streams.Free(Item.Channel.CallBack);
   end OnDisconnect;
   ---------------------------------------------------------------------------

   procedure OnAccept
     (Item : in out ServerCallBack_Type;
      Channel : Network.Streams.Channel_ClassAccess) is
      pragma Warnings(Off,Item);

      NewCallBack : ServerChannelCallBack_Access;

   begin
      Put("Accept Admin Connection");
      New_Line;
      NewCallBack := new ServerChannelCallBack_Type;
      NewCallBack.ReceiveStatus := ReceiveStatusWaitForIdentification;
      NewCallBack.SendStatus    := SendStatusReceive;
      NewCallBack.Channel       := Channel;
      Channel.CallBack
        := Network.Streams.ChannelCallBack_ClassAccess(NewCallBack);
   end OnAccept;
   ---------------------------------------------------------------------------

   procedure Initialize
     (Configuration : Config.Config_Type) is
   begin
      LogImplementation:=
        Logging.Implementations.Find
          (Configuration => Configuration,
           ModuleName    => To_Unbounded_String("Logging"));
      LogContext:=LogImplementation.NewContext
        (Configuration => Configuration,
         ModuleName    => To_Unbounded_String("Control.Admin"));
      LogContext.NewChannel
        (ChannelName => To_Unbounded_String("Server"),
         Channel     => LogMainChannel);

      StreamImplementation:=
        Network.Streams.Implementations.Find
          (Configuration => Configuration,
           ModuleName    => To_Unbounded_String("Admin.Network"));

      StreamImplementation.Initialize.all;

      Server
        :=StreamImplementation.NewServer
          (Config => Config.GetModuleMap
               (Item => Configuration,
                Name => To_Unbounded_String
                  ("Admin.Server.Network")).all);

      Server.CallBack := ServerCallBack'Access;
   end Initialize;
   ---------------------------------------------------------------------------

   procedure Finalize is
   begin
      StreamImplementation.FreeServer
        (Item => Server);
      StreamImplementation.Finalize.all;

      LogImplementation.FreeContext
        (Item => LogContext);
   end Finalize;
   ---------------------------------------------------------------------------

end SimControl.AdminServer;
