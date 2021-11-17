%{
----------------------------------------------------------------------------

This file is part of the Sanworks Bpod repository
Copyright (C) 2021 Sanworks LLC, Rochester, New York, USA

----------------------------------------------------------------------------

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, version 3.

This program is distributed  WITHOUT ANY WARRANTY and without even the 
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  
See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
%}
classdef BpodObject < handle
    properties
        MachineType % 1 = Bpod 0.5, 2 = Bpod 0.7+, 3 = 2.X, 4 = 2+
        FirmwareVersion % An integer specifying the firmware on the connected device
        SerialPort % ArCOM serial port object
        AnalogSerialPort % On state machine r2+ or newer, this is a dedeicated USB serial port to handle analog data
        HW % Hardware description
        Modules % Connected UART serial module description
        ModuleUSB % Struct containing a field for each connected module, listing its paired USB port (i.e. ModuleUSB.ModuleName = 'COM3')
        Status % Struct with system status variables
        Path % Struct with paths to Bpod root folder and specific sub-folders
        Data % Struct storing all data collected in the current session. SaveBpodSessionData saves this to the current data file.
        AnalogDataFile % On Bpod FSM 2+ or newer, a memory-mapped MAT file containing analog data (see matfile() MATLAB docs)
        AnalogThresholdConfig % Struct containing configuration of analog thresholds for Flex I/O channels on FSM 2+, set with obj.setAnalogThreshold()
        StateMatrix % Struct of matrices describing current (running) state machine
        StateMatrixSent % StateMatrix sent to the state machine, for the next trial. At run, this replaces StateMatrix.
        LastStateMatrix % Last state matrix completed. This is updated each time a trial run completes.
        HardwareState % Current state of I/O lines and serial codes
        StateMachineInfo % Struct with information about state machines (customized for connected hardware)
        GUIHandles % Struct with graphics handles
        GUIData % Struct with graphics data
        InputsEnabled % Struct storing input channels that are connected to something. This is modified from the settings menu UI.
        SyncConfig % Struct storing the sync channel and mode (modified from settings menu UI)
        PluginSerialPorts % Struct with serial port objects for plugins (modules)
        PluginFigureHandles % Struct with figure handles for plugins
        PluginObjects % Struct with plugin objects
        SystemSettings % Struct with miscellaneous system settings
        SoftCodeHandlerFunction % The path to an m-file that accepts a byte code from Bpod and executes a MATLAB function (play sound, etc.)
        ProtocolFigures % A struct to hold figures used by the current protocol, which are automatically closed when the user presses the "Stop" button
        ProtocolSettings % The settings struct selected by the user in the launch manager, when launching a protocol
        Emulator % A struct with the internal variables of the emulator (mirror of state machine workspace in Arduino)
        ManualOverrideFlag % Used in the emulator to indicate an override that needs to be handled
        VirtualManualOverrideBytes % Stores emulated event byte codes generated by manual override
        CalibrationTables % Struct for liquid, sound, etc.
        BlankStateMachine % Holds a blank state machine to use with AddState().
        ProtocolStartTime % The time when the current protocol was started.
        BonsaiSocket % An object containing a TCP/IP socket for communication with Bonsai
        EmulatorMode % 0 if actual device connected, 1 if emulator
        HostOS % Holds a string naming the host operating system (i.e. 'Microsoft Windows XP')
        Timers % A struct containing MATLAB timer objects
        LiveTimestamps % Set to 1 if a timestamp is sent with each event, 0 if sent after the trial is complete
    end
    properties (Access = private)
        CurrentFirmware % Struct of current firmware versions for state machine + curated modules 
        SplashData % Splash screen frames
        LastHardwareState % Last known state of I/O lines and serial codes
        CycleMonitoring % 0 = off, 1 = on. Measures min and max actual hardware timer callback execution time
        IsOnline % 1 if connection to Internet is available, 0 if not
    end
    methods
        function obj = BpodObject %Constructor            
            % Add Bpod code to MATLAB path
            BpodPath = fileparts(which('Bpod'));
            addpath(genpath(fullfile(BpodPath, 'Assets')));
            rmpath(genpath(fullfile(BpodPath, 'Assets', 'BControlPatch', 'ExperPort')));
            addpath(genpath(fullfile(BpodPath, 'Examples', 'State Machines')));
            load SplashBGData;
            load SplashMessageData;
            if exist('rng','file') == 2
                rng('shuffle', 'twister'); % Seed the random number generator by CPU clock
            else
                rand('twister', sum(100*fliplr(clock))); % For older versions of MATLAB
            end
            
            % Check for Internet Connection
            obj.IsOnline = obj.check4Internet();
            
            % Validate software version
            if obj.IsOnline
                obj.ValidateSoftwareVersion();
            end
            
            % Initialize fields
            obj.LiveTimestamps = 0;
            obj.SplashData.BG = SplashBGData;
            obj.SplashData.Messages = SplashMessageData;
            obj.GUIHandles.SplashFig = figure('Position',[400 300 485 300],'name','Bpod','numbertitle','off', 'MenuBar', 'none', 'Resize', 'off');
            obj.Status.BpodStartTime = now;
            obj.Status = struct;
            obj.Status.LastTimestamp = 0;
            obj.Status.CurrentStateCode = 0;
            obj.Status.LastStateCode = 0;
            obj.Status.CurrentStateName = '';
            obj.Status.LastStateName = '';
            obj.Status.LastEvent = 0;
            obj.Status.Live = 0;
            obj.Status.Pause = 0;
            obj.Status.InStateMatrix = 0;
            obj.Status.BeingUsed = 0;
            obj.Status.BpodStartTime = 0;
            obj.Status.CurrentProtocolName = '';
            obj.Status.CurrentSubjectName = '';
            obj.Status.SerialPortName = '';
            obj.Status.NewStateMachineSent = 0;
            obj.Status.SessionStartFlag = 0;
            obj.Status.AnalogViewer = 0;
            obj.Status.nAnalogSamples = 0;
            % Initialize paths
            obj.Path = struct;
            obj.Path.BpodRoot = BpodPath;
            obj.Path.ParentDir = fileparts(BpodPath);
            obj.Path.LocalDir = fullfile(obj.Path.ParentDir, 'Bpod Local');
            obj.Path.SettingsDir = fullfile(obj.Path.LocalDir, 'Settings');
            obj.Path.Settings = '';
            obj.Path.DataFolder = '';
            obj.Path.CurrentDataFile = '';
            obj.Path.CurrentProtocol= '';
            obj.Path.InputConfig = fullfile(obj.Path.SettingsDir, 'InputConfig.mat');
            obj.Path.FlexConfig = fullfile(obj.Path.SettingsDir, 'FlexConfig.mat');
            obj.Path.SyncConfig = fullfile(obj.Path.SettingsDir, 'SyncConfig.mat');
            obj.Path.ModuleUSBConfig = fullfile(obj.Path.SettingsDir, 'ModuleUSBConfig.mat');
            
            % Initialize state machine info, to be populated in SetupStateMachine()
            obj.StateMachineInfo = struct;
            obj.StateMachineInfo.nEvents = 0; % Number of events the state machine can respond to
            obj.StateMachineInfo.EventNames = 0; % Cell array of strings with names for each event
            obj.StateMachineInfo.InputChannelNames = 0; % cell array of strings with names for input channels
            obj.StateMachineInfo.nOutputChannels = 0; % Number of output channels
            obj.StateMachineInfo.OutputChannelNames = 0; % Cell array of strings with output channel names
            obj.StateMachineInfo.MaxStates = 0; % Maximum number of states the attached Bpod can store
            
            % Ensure that settings, data, protocol and calibration folders exist
            if ~exist(obj.Path.LocalDir)
                mkdir(obj.Path.LocalDir);
            end
            if ~exist(obj.Path.SettingsDir)
                mkdir(obj.Path.SettingsDir);
            end
            addpath(genpath(obj.Path.SettingsDir));
            if exist('BpodSettings.mat') > 0
                load BpodSettings;
                obj.SystemSettings = BpodSettings;
            else
                obj.SystemSettings = struct;
            end
            obj.Path.ProtocolFolder = '';
            if isfield(obj.SystemSettings, 'ProtocolFolder')
                if exist(obj.SystemSettings.ProtocolFolder)
                    obj.Path.ProtocolFolder = obj.SystemSettings.ProtocolFolder;
                end
            end
            obj.Path.DataFolder = '';
            if isfield(obj.SystemSettings, 'DataFolder')
                if exist(obj.SystemSettings.DataFolder)
                    obj.Path.DataFolder = obj.SystemSettings.DataFolder;
                end
            end
            obj.Path.BcontrolRootFolder = '';
            if isfield(obj.SystemSettings, 'BcontrolRootFolder')
                if exist(obj.SystemSettings.BcontrolRootFolder) == 7
                    obj.Path.BcontrolRootFolder = obj.SystemSettings.BcontrolRootFolder;
                    ExperPortFolder = fullfile(obj.Path.BcontrolRootFolder, 'ExperPort');
                    if exist(ExperPortFolder) == 7
                        addpath(ExperPortFolder);
                    end
                end
            end
            
            obj.HostOS = system_dependent('getos');
            CalFolder = fullfile(obj.Path.LocalDir,'Calibration Files');
            if ~exist(CalFolder)
                mkdir(CalFolder);
                copyfile(fullfile(obj.Path.BpodRoot, 'Examples', 'Example Calibration Files'), CalFolder);
                questdlg('Calibration folder created in /BpodLocal/. Replace example calibration files soon.', ...
                    'Calibration folder not found', ...
                    'Ok', 'Ok');
            end
            % Liquid
            try
                LiquidCalibrationFilePath = fullfile(obj.Path.LocalDir, 'Calibration Files', 'LiquidCalibration.mat');
                load(LiquidCalibrationFilePath);
                obj.CalibrationTables.LiquidCal = LiquidCal;
            catch
                obj.CalibrationTables.LiquidCal = [];
            end
            % Sound
            try
                SoundCalibrationFilePath = fullfile(obj.Path.LocalDir, 'Calibration Files', 'SoundCalibration.mat');
                load(SoundCalibrationFilePath);
                obj.CalibrationTables.SoundCal = SoundCal;
            catch
                obj.CalibrationTables.SoundCal = [];
            end
            % Load input channel settings
            if ~exist(obj.Path.InputConfig)
                copyfile(fullfile(obj.Path.BpodRoot, 'Examples', 'Example Settings Files', 'InputConfig.mat'), obj.Path.InputConfig);
            end
            load(obj.Path.InputConfig);
            obj.InputsEnabled = BpodInputConfig;
            % Load sync settings
            if ~exist(obj.Path.SyncConfig)
                copyfile(fullfile(obj.Path.BpodRoot, 'Examples', 'Example Settings Files', 'SyncConfig.mat'), obj.Path.SyncConfig);
            end
            load(obj.Path.SyncConfig);
            obj.SyncConfig = BpodSyncConfig;
            
            % Create module USB port config file (if not present)
            if ~exist(obj.Path.ModuleUSBConfig)
                copyfile(fullfile(obj.Path.BpodRoot, 'Examples', 'Example Settings Files', 'ModuleUSBConfig.mat'), obj.Path.ModuleUSBConfig);
            end
            
            % Load list of current firmware versions
            CF = CurrentFirmwareList; % Located in /Functions/Internal Functions/, returns list of current firmware
                                      % for state machine and modules
            obj.CurrentFirmware = CF;
            % Create timer objects
            obj.Timers = struct;
            obj.Timers.PortRelayTimer = timer('TimerFcn','UpdateSerialTerminals()', 'ExecutionMode', 'fixedRate', 'Period', 0.1);
            obj.Timers.AnalogTimer = timer('TimerFcn',@(h,e)obj.ProcessAnalogSamples(), 'ExecutionMode', 'fixedRate', 'Period', 0.1);
            obj.BpodSplashScreen(1);
        end
        
        function obj = resetSessionClock(obj)
            if obj.EmulatorMode == 0
                obj.SerialPort.write('*', 'uint8'); % Reset session clock
                Confirmed = obj.SerialPort.read(1,'uint8');
                if Confirmed ~= 1
                    error('Error: confirm not returned after resetting session clock.')
                end
            end
        end
        
        function obj = setupFolders(obj)
            if ispc
                FigHeight = 130; Label1Ypos = 28; Label2Ypos = 68;
            else
                FigHeight = 150; Label1Ypos = 38; Label2Ypos = 75;
            end
            obj.GUIHandles.FolderConfigFig = figure('Position', [350 480 600 FigHeight],'name','Setup folders','numbertitle','off', 'MenuBar', 'none', 'Resize', 'off');
            ha = axes('units','normalized', 'position',[0 0 1 1]);
            uistack(ha,'bottom');
            BG = imread('SettingsMenuBG2.bmp');
            imagesc(BG); axis off; drawnow;
            text(10, Label1Ypos,'Protocols','Parent', ha , 'FontName', 'OCRAStd', 'FontSize', 13, 'Color', [0.8 0.8 0.8]);
            text(10, Label2Ypos,'Data Root','Parent', ha , 'FontName', 'OCRAStd', 'FontSize', 13, 'Color', [0.8 0.8 0.8]);
            if isfield(obj.SystemSettings, 'ProtocolFolder')
                if isempty(obj.SystemSettings.ProtocolFolder)
                    ProtocolPath = fullfile(obj.Path.LocalDir, 'Protocols',filesep);
                else
                    ProtocolPath = obj.SystemSettings.ProtocolFolder;
                end
            else
                ProtocolPath = fullfile(obj.Path.LocalDir, 'Protocols',filesep);
            end
            if isfield(obj.SystemSettings, 'DataFolder')
                if isempty(obj.SystemSettings.DataFolder)
                    DataPath = fullfile(obj.Path.LocalDir, 'Data',filesep);
                else
                    DataPath = obj.SystemSettings.DataFolder;
                end
            else
                DataPath = fullfile(obj.Path.LocalDir, 'Data',filesep);
            end
            ImportButtonGFX = imread('ImportButton.bmp');
            obj.GUIHandles.setupFoldersButton = uicontrol(obj.GUIHandles.FolderConfigFig, 'Style', 'pushbutton', 'String', 'Ok', 'Position', [270 10 60 25], 'Callback', @(h,e)obj.setFolders(), 'BackgroundColor', [.4 .4 .4], 'ForegroundColor', [1 1 1]);
            obj.GUIHandles.dataFolderEdit = uicontrol(obj.GUIHandles.FolderConfigFig, 'Style', 'edit', 'String', DataPath, 'Position', [140 50 410 25], 'HorizontalAlignment', 'Left', 'BackgroundColor', [.8 .8 .8], 'FontSize', 10, 'FontName', 'Arial');
            obj.GUIHandles.dataFolderNav = uicontrol(obj.GUIHandles.FolderConfigFig, 'Style', 'pushbutton', 'String', '', 'Position', [560 50 25 25], 'BackgroundColor', [.8 .8 .8], 'CData', ImportButtonGFX, 'Callback', @(h,e)obj.folderSetupUIGet('Data'));
            obj.GUIHandles.protocolFolderEdit = uicontrol(obj.GUIHandles.FolderConfigFig, 'Style', 'edit', 'String', ProtocolPath, 'Position', [140 90 410 25], 'HorizontalAlignment', 'Left', 'BackgroundColor', [.8 .8 .8], 'FontSize', 10, 'FontName', 'Arial');
            obj.GUIHandles.protocolFolderNav = uicontrol(obj.GUIHandles.FolderConfigFig, 'Style', 'pushbutton', 'String', '', 'Position', [560 90 25 25], 'BackgroundColor', [.8 .8 .8], 'CData', ImportButtonGFX, 'Callback', @(h,e)obj.folderSetupUIGet('Protocol'));
        end
        function obj = folderSetupUIGet(obj, type)
            switch type
                case 'Data'
                    OriginalFolder = get(obj.GUIHandles.dataFolderEdit, 'String');
                    ChosenFolder = uigetdir(obj.Path.LocalDir, 'Select Bpod data folder');
                    if ChosenFolder == 0
                        ChosenFolder = OriginalFolder;
                    end
                    set(obj.GUIHandles.dataFolderEdit, 'String', fullfile(ChosenFolder, filesep));
                case 'Protocol'
                    OriginalFolder = get(obj.GUIHandles.protocolFolderEdit, 'String');
                    ChosenFolder = uigetdir(obj.Path.LocalDir, 'Select Bpod protocol folder');
                    if ChosenFolder == 0
                        ChosenFolder = OriginalFolder;
                    end
                    set(obj.GUIHandles.protocolFolderEdit, 'String', fullfile(ChosenFolder, filesep));
            end
        end
        function obj = setFolders(obj)
            DataFolder = get(obj.GUIHandles.dataFolderEdit, 'String');
            ProtocolFolder = get(obj.GUIHandles.protocolFolderEdit, 'String');
            if exist(DataFolder) == 0
                mkdir(DataFolder);
            end
            if exist(ProtocolFolder) == 0
                mkdir(ProtocolFolder);
            end
            Contents = dir(ProtocolFolder);
            if length(Contents) == 2
                choice = questdlg('Copy example protocols to new protocol folder?', ...
                    'Protocol folder is empty', ...
                    'Yes', 'No', 'No');
                if strcmp(choice, 'Yes')
                    copyfile(fullfile(obj.Path.BpodRoot, 'Examples', 'Protocols'), ProtocolFolder);
                end
            end
            obj.Path.ProtocolFolder = ProtocolFolder;
            obj.Path.DataFolder = DataFolder;
            obj.SystemSettings.ProtocolFolder = ProtocolFolder;
            obj.SystemSettings.DataFolder = DataFolder;
            obj.SaveSettings;
            close(obj.GUIHandles.FolderConfigFig);
        end
        function obj = Wiki(obj)
            if ispc || ismac
                web ('https://www.sites.google.com/site/bpoddocumentation/home', '-browser');
            else
                disp('**NOTE** If MATLAB is running as root, Firefox may fail to open. The wiki is at: https://www.sites.google.com/site/bpoddocumentation/home');
                web ('https://www.sites.google.com/site/bpoddocumentation/home');
            end
        end
        function obj = SaveSettings(obj)
            BpodSettings = obj.SystemSettings;
            save(fullfile(obj.Path.LocalDir, 'Settings', 'BpodSettings.mat'), 'BpodSettings');
        end
        function obj = BeingUsed(obj)
            error('Error: "BpodSystem.BeingUsed" is now "BpodSystem.Status.BeingUsed" - Please update your protocol!')
        end
        function obj = SetStatusLED(obj, status)
            if obj.EmulatorMode == 0
                if obj.FirmwareVersion < 23
                    error('Error: status LED enable/disable requires firmware v23+');
                end
                if (status == 1) || (status == 0)
                    obj.SerialPort.write([':' status], 'uint8');
                    Confirmed = obj.SerialPort.read(1, 'uint8');
                else
                    error('Error: LED status must be 0 (disabled) or 1 (enabled)')
                end
            end
        end
        function StartModuleRelay(obj, Module)
            if ischar(Module)
                ModuleNum = find(strcmp(Module, obj.Modules.Name));
            end
            if ~isempty(ModuleNum)
                if (ModuleNum <= length(obj.Modules.Connected))
                    if (sum(obj.Modules.RelayActive)) == 0
                        obj.SerialPort.write(['J' ModuleNum-1 1], 'uint8');
                        obj.Modules.RelayActive(ModuleNum) = 1;
                    else
                        error('Error: You must stop the active module relay with StopModuleRelay() before starting another one.')
                    end
                end
            end
        end
        function StopModuleRelay(obj, varargin) 
            for i = 1:length(obj.Modules.RelayActive)
                obj.SerialPort.write(['J' i 0], 'uint8');
            end
            RunningState = get(obj.Timers.PortRelayTimer, 'Running');
            if strcmp(RunningState, 'on')
                stop(obj.Timers.PortRelayTimer);
                while strcmp(RunningState, 'on')
                    RunningState = get(obj.Timers.PortRelayTimer, 'Running');
                    pause(.001);
                end
            end
            nAvailable = obj.SerialPort.bytesAvailable;
            if nAvailable > 0
                trash = obj.SerialPort.read(nAvailable, 'uint8');
            end
            obj.Modules.RelayActive(1:end) = 0;
        end
        function setFlexIO(obj, channelTypes)
            % ChannelTypes: 0 = DI, 1 = DO, 2 = ADC, 3 = DAC
            if length(channelTypes) ~= obj.HW.n.FlexIO
                error(['Error using setFlexIO: the channelTypes vector must specify one type for each of the ' num2str(obj.HW.n.FlexIO) ' FlexIO channels.']);
            end
            if (sum(channelTypes > 3) > 0) || (sum(channelTypes < 0) > 0)
                error('Error using setFlexIO: invalid channel type specified. Valid channel types are: 0 = DI, 1 = DO, 2 = ADC, 3 = DAC');
            end
            if obj.Status.InStateMatrix
                error('Error: FlexIO channels cannot be reconfigured while the state machine is running.');
            end
            obj.SerialPort.write(['Q' channelTypes], 'uint8');
            OK = obj.SerialPort.read(1, 'uint8');
            if OK ~= 1
                error('Error configuring FlexIO channels: confirm code not returned');
            end
            % Reconfigure events and outputs
            obj.HW.FlexIOChannelTypes = channelTypes;
            InputChannelNames = cell(1,obj.HW.n.FlexIO);
            OutputChannelNames = cell(1,obj.HW.n.FlexIO);
            FlexEventPos = obj.HW.Pos.Event_FlexIO;
            FlexInputPos = obj.HW.Pos.Input_FlexIO;
            FlexOutputPos = obj.HW.Pos.Output_FlexIO;
            for i = 1:obj.HW.n.FlexIO
                switch channelTypes(i)
                    case 0
                        InputChannelNames{i} = ['Flex' num2str(i)];
                        OutputChannelNames{i} = '---';
                        obj.StateMachineInfo.EventNames{FlexEventPos} = [InputChannelNames{i} 'High'];
                        obj.StateMachineInfo.EventNames{FlexEventPos+1} = [InputChannelNames{i} 'Low'];
                        FlexEventPos = FlexEventPos + 2;
                    case 1
                        InputChannelNames{i} = '---';
                        OutputChannelNames{i} = ['Flex' num2str(i) 'DO'];
                        obj.StateMachineInfo.EventNames{FlexEventPos} = '---';
                        obj.StateMachineInfo.EventNames{FlexEventPos+1} = '---';
                        FlexEventPos = FlexEventPos + 2;
                    case 2
                        InputChannelNames{i} = ['Flex' num2str(i)];
                        OutputChannelNames{i} = '---';
                        obj.StateMachineInfo.EventNames{FlexEventPos} = [InputChannelNames{i} 'Trig1'];
                        obj.StateMachineInfo.EventNames{FlexEventPos+1} = [InputChannelNames{i} 'Trig2'];
                        FlexEventPos = FlexEventPos + 2;
                    case 3
                        InputChannelNames{i} = '---';
                        OutputChannelNames{i} = ['Flex' num2str(i) 'AO'];
                        obj.StateMachineInfo.EventNames{FlexEventPos} = '---';
                        obj.StateMachineInfo.EventNames{FlexEventPos+1} = '---';
                        FlexEventPos = FlexEventPos + 2;
                end
            end
            obj.StateMachineInfo.InputChannelNames(FlexInputPos:FlexInputPos+obj.HW.n.FlexIO-1) = InputChannelNames;
            obj.StateMachineInfo.OutputChannelNames(FlexOutputPos:FlexOutputPos+obj.HW.n.FlexIO-1) = OutputChannelNames;
        end
        function setFlexIO_AnalogInputSF(obj, SF)
            % Set FlexIO analog input sampling rate (Hz). Permitted range = [1, 1000]
            nCyclesPerSample = obj.HW.CycleFrequency/SF; % Number of state machine cycles per analog sample
            if nCyclesPerSample < 10 || nCyclesPerSample > obj.HW.CycleFrequency
                error('Error configuring FlexIO analog input sampling rate: Rate must be in range [1, 1000]');
            end
            obj.SerialPort.write('^', 'uint8', nCyclesPerSample, 'uint32');
            OK = obj.SerialPort.read(1, 'uint8');
            if OK ~= 1
                error('Error configuring FlexIO analog input sampling rate: confirm code not returned');
            end
            obj.HW.FlexIOSamplingRate = SF;
        end
        function PhoneHomeOpt_In_Out(obj)
            obj.GUIHandles.BpodPhoneHomeFig = figure('Position', [550 180 400 350],...
                'name','Bpod Phone Home','numbertitle','off', 'MenuBar', 'none', 'Resize', 'off');
            ha = axes('units','normalized', 'position',[0 0 1 1]);
            uistack(ha,'bottom');
            BG = imread('PhoneHomeBG.bmp');
            image(BG); axis off; drawnow;
            text(20, 40,'Bpod PhoneHome Program', 'FontName', 'Courier New', 'FontSize', 16, 'Color', [1 1 1]);
            Pos = 80; Step = 25;
            text(20, Pos,'Bpod PhoneHome is an opt-in', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step;
            text(20, Pos,'program to send anonymous data', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step;
            text(20, Pos,'about your Bpod software setup', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step;
            text(20, Pos,'to Sanworks LLC on Bpod start.', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step;
            text(20, Pos,'This will help us understand', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step;
            text(20, Pos,'which MATLAB versions and OS', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step;
            text(20, Pos,'flavors typically run Bpod', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step;
            text(20, Pos,'+ how many rigs are out there.', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step+5;
            text(140, Pos,'See BpodPhoneHome.m', 'FontName', 'Courier New', 'FontSize', 12, 'Color', [1 1 1]); Pos = Pos + Step;
            BpodSystem.GUIHandles.PhoneHomeAcceptBtn = uicontrol('Style', 'pushbutton', 'String', 'Ok',...
                'Position', [130 15 120 40], 'Callback', @(h,e)obj.phoneHomeRegister(1),...
                'FontSize', 12,'Backgroundcolor',[0.29 0.29 0.43],'Foregroundcolor',[0.9 0.9 0.9], 'FontName', 'Courier New');
            BpodSystem.GUIHandles.PhoneHomeAcceptBtn = uicontrol('Style', 'pushbutton', 'String', 'Decline',...
                'Position', [260 15 120 40], 'Callback', @(h,e)obj.phoneHomeRegister(0),...
                'FontSize', 12,'Backgroundcolor',[0.29 0.29 0.43],'Foregroundcolor',[0.9 0.9 0.9], 'FontName', 'Courier New');
        end
        function OnlineStatus = check4Internet(obj)
           if ispc
                [a,reply]=system('ping -n 1 -w 1000 www.google.com'); % Check for connection
                ConnectConfirmString = 'Received = 1';
            elseif ismac
                [a,reply]=system('trap -SIGALRM; ping -c 1 -t 1 www.google.com'); % Check for connection
                ConnectConfirmString = '1 packets received';
            else
                [a,reply]=system('timeout 1 ping -c 1 www.google.com'); % Check for connection
                ConnectConfirmString = '1 received';
            end
            OnlineStatus = 0;
            if ~isempty(strfind(reply, ConnectConfirmString))
                OnlineStatus = 1;
            end
        end
        
        function startAnalogViewer(obj)
            obj.analogViewer('init', []);
        end
        
        function delete(obj) % Destructor
            obj.SerialPort = []; % Trigger the ArCOM port's destructor function (closes and releases port)
            if obj.MachineType > 3 && obj.FirmwareVersion > 22
                obj.AnalogSerialPort = [];
            end 
        end
    end
    methods (Access = private)    
       function phoneHomeRegister(obj, state)
           if ~isfield(obj.SystemSettings, 'PhoneHomeRigID')
              obj.SystemSettings.PhoneHomeRigID = char(floor(rand(1,16)*25)+65);
           end
            switch state
                case 0
                    obj.SystemSettings.PhoneHome = 0;
                    obj.BpodPhoneHome('Opt_Out');
                case 1
                    obj.SystemSettings.PhoneHome = 1;
                    obj.BpodPhoneHome(0);
            end
            obj.SaveSettings;
            close(obj.GUIHandles.BpodPhoneHomeFig);
       end
        function SwitchPanels(obj, panel)
            obj.GUIData.CurrentPanel = 0;
            OffPanels = 1:obj.HW.n.UartSerialChannels+1;
            OffPanels = OffPanels(OffPanels~=panel);
            set(obj.GUIHandles.OverridePanel(panel), 'Visible', 'on');
            uistack(obj.GUIHandles.OverridePanel(panel), 'top');
            for i = OffPanels
                % Button -> gray
                set(obj.GUIHandles.PanelButton(i), 'BackgroundColor', [0.37 0.37 0.37]);
                set(obj.GUIHandles.OverridePanel(i), 'Visible', 'off');
            end
            set(obj.GUIHandles.PanelButton(panel), 'BackgroundColor', [0.45 0.45 0.45]);
            if isempty(strfind(obj.HostOS, 'Linux')) && ~verLessThan('matlab', '8.0.0') && verLessThan('matlab', '9.5.0')
                for i = 1:obj.HW.n.SerialChannels
                    jButton = findjobj(obj.GUIHandles.PanelButton(i));
                    jButton.setBorderPainted(false);
                end
            end
            obj.GUIData.CurrentPanel = panel;
            if obj.EmulatorMode == 0
                % Set module byte stream relay to current module
                obj.StopModuleRelay;
                if panel > 1 
                    if obj.Status.BeingUsed == 0 && obj.GUIData.DefaultPanel(panel) == 1
                        obj.SerialPort.write(['J' panel-2 1], 'uint8');
                        obj.Modules.RelayActive(panel-1) = 1;
                        % Start timer to scan port
                        start(obj.Timers.PortRelayTimer);
                    end
                end
            end
            obj.FixPushbuttons;
        end
        
        function FixPushbuttons(obj)
            % Remove all the nasty borders around pushbuttons on platforms besides win7
            if isempty(strfind(obj.HostOS, 'Windows 7'))
                warning off
                handles = findjobj('class', 'pushbutton');
                set(handles, 'border', []);
                warning on
            end
        end
        
        function BpodSplashScreen(obj, Stage)
            if Stage == 1
                ha = axes('units','normalized', 'position',[0 0 1 1]);
                uistack(ha,'bottom');
            end
            Img = obj.SplashData.BG;
            Img(201:240,1:485) = obj.SplashData.Messages(:,:,Stage);
            Img(270:274, 43:442) = ones(5,400)*128;
            StartPos = 43;
            EndPos = 44;
            StepSize = 5;
            if ~verLessThan('matlab', '9')
            	StepSize = 10;
            end
            switch Stage
                case 1
                    while EndPos < 123
                        EndPos = EndPos + StepSize;
                        Img(270:274, StartPos:EndPos) = ones(5,(EndPos-(StartPos-1)))*20;
                        imagesc(Img); colormap('gray'); set(gcf,'name','Bpod','numbertitle','off', 'MenuBar', 'none', 'Resize', 'off'); axis off; drawnow;
                    end
                case 2
                    EndPos = 123;
                    while EndPos < 203
                        EndPos = EndPos + StepSize;
                        Img(270:274, StartPos:EndPos) = ones(5,(EndPos-(StartPos-1)))*20;
                        imagesc(Img); colormap('gray'); set(gcf,'name','Bpod','numbertitle','off', 'MenuBar', 'none', 'Resize', 'off'); axis off; drawnow;
                    end
                case 3
                    EndPos = 203;
                    while EndPos < 283
                        EndPos = EndPos + StepSize;
                        Img(270:274, StartPos:EndPos) = ones(5,(EndPos-(StartPos-1)))*20;
                        imagesc(Img); colormap('gray'); set(gcf,'name','Bpod','numbertitle','off', 'MenuBar', 'none', 'Resize', 'off'); axis off; drawnow;
                    end
                case 4
                    EndPos = 283;
                    while EndPos < 363
                        EndPos = EndPos + StepSize;
                        Img(270:274, StartPos:EndPos) = ones(5,(EndPos-(StartPos-1)))*20;
                        imagesc(Img); colormap('gray'); set(gcf,'name','Bpod','numbertitle','off', 'MenuBar', 'none', 'Resize', 'off'); axis off; drawnow;
                    end
                case 5
                    EndPos = 363;
                    while EndPos < 442
                        EndPos = EndPos + StepSize;
                        Img(270:274, StartPos:EndPos) = ones(5,(EndPos-(StartPos-1)))*20;
                        imagesc(Img); colormap('gray'); set(gcf,'name','Bpod','numbertitle','off', 'MenuBar', 'none', 'Resize', 'off'); axis off; drawnow;
                    end
                    pause(.5);
            end
        end
    end
end