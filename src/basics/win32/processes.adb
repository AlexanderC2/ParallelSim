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

with Interfaces.C;
with Interfaces.C.Strings;
with Win32.Kernel32;
with GNAT.OS_Lib;
with GNAT.Strings;
with Ada.Directories; use Ada.Directories;
with System;
with ProcessLoop;

with Ada.IO_Exceptions;
with Ada.Text_IO; use Ada.Text_IO;

package body Processes is

   PathDirectories       : StringList_Pack.List;
   PathDirectoriesLoaded : Boolean:=False;

   procedure LoadPathDirectories is

      PathEnv : GNAT.OS_Lib.String_Access;
      Start   : Integer;

   begin

      if PathDirectoriesLoaded then
         return;
      end if;

      PathEnv := GNAT.OS_Lib.Getenv("PATH");
      Start   := PathEnv.all'First;
      Put_Line("PATH:"&PathEnv.all);
      for i in PathEnv.all'Range loop
         if PathEnv.all(i)=';' then
            -- Take String Start..i-1 if i-1-start>0 and add it to the list
            if i-Start>=1 then
               PathDirectories.Append(U(PathEnv.all(Start..i-1)));
            end if;
            Start:=i+1;
         end if;
      end loop;
      if Start<=PathEnv.all'Last then
         PathDirectories.Append(U(PathEnv.all(Start..PathEnv.all'Last)));
      end if;
      PathDirectoriesLoaded:=True;
      GNAT.Strings.Free(PathEnv);

   end LoadPathDirectories;
   ---------------------------------------------------------------------------

   procedure FindInPathDirectories
     (FileName : Unbounded_String;
      FullName : out Unbounded_String;
      Success  : out Boolean) is

      use type StringList_Pack.Cursor;

      Cursor : StringList_Pack.Cursor;

   begin
      LoadPathDirectories;
      Cursor:=PathDirectories.First;
      while Cursor/=StringList_Pack.No_Element loop
         declare
            Search   : Search_Type;
            DirEntry : Directory_Entry_Type;
         begin
            Start_Search
              (Search    => Search,
               Directory => To_String(StringList_Pack.Element(Cursor)),
               Pattern   => To_String(FileName)&".exe",
               Filter    => (Ordinary_File => True, others => False));
            if More_Entries(Search) then
               Get_Next_Entry
                 (Search          => Search,
                  Directory_Entry => DirEntry);
               FullName:=U(Full_Name(DirEntry));
               End_Search(Search);
               Success:=True;
               return;
            end if;
            End_Search(Search);
         exception
            when Ada.IO_Exceptions.Name_Error =>
               null; -- Ignore exception for invalid paths
         end;
         Cursor:=StringList_Pack.Next(Cursor);
      end loop;
      Success:=False;
      return;
   end FindInPathDirectories;
   ---------------------------------------------------------------------------

   procedure ProcessQueue
     (Object : AnyObject_ClassAccess) is

      use type Win32.DWORD_Type;

      Process   : constant Process_Access:=Process_Access(Object);
      ExitCode  : aliased Win32.DWORD_Type;
      BytesRead : aliased Win32.DWORD_Type:=0;

   begin
      if not Win32.Kernel32.GetExitCodeProcess
        (hProcess   => Process.P.ProcessHandle,
         lpExitCode => ExitCode'Access) then
         Put_Line("GetExitCode failed******************************************");
      end if;
      if ExitCode/=Win32.STILL_ACTIVE then
         -- TODO: Report this !!!
         return;
      end if;

      if not Win32.Kernel32.PeekNamedPipe
        (hNamedPipe             => Process.P.StdOutPipeIn,
         lpBuffer               => null,
         nBufferSize            => 0,
         lpBytesRead            => null,
         lpTotalBytesAvail      => BytesRead'Access,
         lpBytesLeftThisMessage => null) then
         Put_Line("Failed call to PeekNamedPipe?");
         return;
      end if;

      if BytesRead=0 then
         return;
      end if;

      if Process.Buffer=null then
         Process.Buffer:=new ByteArray_Type(0..1023);
      end if;

      if not Win32.Kernel32.ReadFile
        (hFile                => Process.P.StdOutPipeIn,
         lpBuffer             => Process.Buffer,
         nNumberOfBytesToRead => Process.Buffer'Length,
         lpNumberOfBytesRead  => BytesRead'Access,
         lpOverlapped         => null) then
         Put_Line("Failed to Read File");
         return;
      end if;

      for i in 0..Integer(BytesRead)-1 loop
         case Process.Buffer(i) is
            when 10 =>
               declare
                  Str : Unbounded_String;
               begin
                  Process.CharacterBuffer.ReadString(Str);
                  if Process.OnMessage/=null then
                     Process.OnMessage(Process.CallBackObject,Str);
                  end if;
               end;
            when 13 =>
               null;
            when others =>
               Process.CharacterBuffer.AddCharacter(Character'Val(Process.Buffer(i)));
         end case;
      end loop;

   end ProcessQueue;
   ---------------------------------------------------------------------------

   procedure Kill
     (Item : access Process_Type) is

      use type Win32.HANDLE_Type;
      use type Interfaces.C.int;

   begin
      if Item.P.ProcessHandle/=Win32.NULLHANDLE then
         if not Win32.Kernel32.TerminateProcess(Item.P.ProcessHandle,0) then
            null;
         end if;
         if Win32.Kernel32.CloseHandle(Item.P.StdOutPipeIn)=0 then
            null;
         end if;
         if Win32.Kernel32.CloseHandle(Item.P.StdOutPipeOut)=0 then
            null;
         end if;
         Item.P.ProcessHandle := Win32.NULLHANDLE;
         Item.P.StdOutPipeIn  := Win32.NULLHANDLE;
         Item.P.StdOutPipeOut := Win32.NULLHANDLE;
         ProcessLoop.Remove(ProcessQueue'Access,AnyObject_ClassAccess(Item));
      end if;
   end Kill;
   ---------------------------------------------------------------------------

   procedure Execute
     (Item        : access Process_Type;
      ProgramName : Unbounded_String;
      Arguments   : Unbounded_String) is

      use type Win32.DWORD_Type;
      use type Interfaces.C.ptrdiff_t;

      use type Interfaces.C.int;
      use type Interfaces.Unsigned_32;

      CProgramName    : Interfaces.C.Strings.chars_ptr;
      CParameters     : Interfaces.C.Strings.chars_ptr;
      FullProgramName : Unbounded_String;

   begin

      declare
         Success : Boolean;
      begin
         FindInPathDirectories
           (FileName => ProgramName,
            FullName => FullProgramName,
            Success  => Success);
         if not Success then
            raise ExecutableNotFound with To_String(ProgramName);
         end if;
      end;

      declare
         SecAttr : aliased Win32.SECURITY_ATTRIBUTES_Type;
      begin
         SecAttr.nLength        := SecAttr'Size/8;
         SecAttr.bInheritHandle := 1;
         if not Win32.Kernel32.CreatePipe
           (hReadPipe        => Item.P.StdOutPipeIn'Access,
            hWritePipe       => Item.P.StdOutPipeOut'Access,
            lpPipeAttributes => SecAttr'Access,
            nSize            => 0) then
            raise FailedToCreatePipe with
              Win32.DWORD_Type'Image(Win32.GetLastError);
         end if;
         if not Win32.Kernel32.SetHandleInformation
           (hObject => Item.P.StdOutPipeIn,
            dwMask  => Win32.HANDLE_FLAG_INHERIT,
            dwFlags => 0) then
            if Win32.Kernel32.CloseHandle(Item.P.StdOutPipeIn)=0 then
               null;
            end if;
            if Win32.Kernel32.CloseHandle(Item.P.StdOutPipeOut)=0 then
               null;
            end if;
            raise FailedExecute with "SetHandleInformation;"
              &Win32.DWORD_Type'Image(Win32.GetLastError);
         end if;
      end;

      -- TODO: Check if escaping is safe
      CProgramName := Interfaces.C.Strings.New_String(To_String(FullProgramName));
      CParameters  := Interfaces.C.Strings.New_String(To_String(""""&FullProgramName&""" "&Arguments));

      declare
         StartInfo   : aliased Win32.STARTUPINFO_Type;
         ProcessInfo : aliased Win32.PROCESS_INFORMATION_Type;
      begin

         StartInfo.cb         := StartInfo'Size/8;
         StartInfo.hStderr    := Item.P.StdOutPipeOut;
         StartInfo.hStdOutput := Item.P.StdOutPipeOut;
         StartInfo.hStdInput  := Win32.NULLHANDLE;
         StartInfo.dwFlags    := Win32.STARTF_USESTDHANDLES;

         if Win32.Kernel32.CreateProcess
           (lpApplicationName    => CProgramName,
            lpCommandLine        => CParameters,
            lpProcessAttributes  => null,
            lpThreadAttributes   => null,
            bInheritHandles      => 1,
            dwCreationFlags      => 0,
            lpEnvironment        => System.Null_Address,
            lpCurrentDirectory   => Interfaces.C.Strings.Null_Ptr,
            lpStartupInfo        => StartInfo'Access,
            lpProcessInformation => ProcessInfo'Access)=0 then
            if Win32.Kernel32.CloseHandle(Item.P.StdOutPipeIn)=0 then
               null;
            end if;
            if Win32.Kernel32.CloseHandle(Item.P.StdOutPipeOut)=0 then
               null;
            end if;
            Interfaces.C.Strings.Free(CProgramName);
            Interfaces.C.Strings.Free(CParameters);
            raise FailedExecute with "CreateProcess;"
              &Win32.DWORD_Type'Image(Win32.GetLastError);
         end if;
         if Win32.Kernel32.CloseHandle(ProcessInfo.hThread)=0 then
            Put_Line("Failed to close Handle");
         end if;
         -- TODO: Copy ProcessID for later
         Item.P.ProcessHandle:=ProcessInfo.hProcess;
      end;

      Interfaces.C.Strings.Free(CProgramName);
      Interfaces.C.Strings.Free(CParameters);

      ProcessLoop.Add(ProcessQueue'Access,AnyObject_ClassAccess(Item));
      Put_Line("Processes added to pipe queue");

   end Execute;
   ---------------------------------------------------------------------------

end Processes;
