// --
// OTOBO is a web-based ticketing system for service organisations.
// --
// Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
// Copyright (C) 2021-2024 Znuny GmbH, https://znuny.org/
// Copyright (C) 2019-2024 Rother OSS GmbH, https://otobo.de/
// --
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later version.
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
// --

"use strict";

var Core = Core || {};
Core.UI = Core.UI || {};
var CKEditorInstances = [];

/**
 * @namespace Core.UI.RichTextEditor
 * @memberof Core.UI
 * @author
 * @description
 *      Richtext Editor.
 */
Core.UI.RichTextEditor = (function (TargetNS) {
    /**
     * @private
     * @name $FormID
     * @memberof Core.UI.RichTextEditor
     * @member {jQueryObject}
     * @description
     *      Hidden input field with name FormID.
     */
    var $FormID,

        /**
         * @private
         * @name TimeOutRTEOnChange
         * @memberof Core.UI.RichTextEditor
         * @member {Object}
         * @description
         *      Object to handle timeout.
         */
        TimeOutRTEOnChange;

    /**
     * @private
     * @name CheckFormID
     * @memberof Core.UI.RichTextEditor
     * @function
     * @returns {jQueryObject} FormID element.
     * @param {jQueryObject} $EditorArea - The jQuery object of the element that has become a rich text editor.
     * @description
     *      Check in the window which hidden element has a name same to 'FormID' and return it like a JQuery object.
     */
    function CheckFormID($EditorArea) {
        if (typeof $FormID === 'undefined') {
            $FormID = $EditorArea.closest('form').find('input:hidden[name=FormID]');
        }
        return $FormID;
    }

    /**
     * @name InitEditor
     * @memberof Core.UI.RichTextEditor
     * @function
     * @returns {Boolean} Returns false on error.
     * @param {jQueryObject} $EditorArea - The jQuery object of the element that will be a rich text editor.
     * @description
     *      This function initializes the application and executes the needed functions.
     */
    TargetNS.InitEditor = function ($EditorArea) {
        var EditorID = '',
            UserLanguage,
            EnabledPlugins = CheckFormID($EditorArea).length ? Core.Config.Get('RichText.Toolbar') : Core.Config.Get('RichText.ToolbarWithoutImage'),
            CustomerInterface = (Core.Config.Get('SessionName') === Core.Config.Get('CustomerPanelSessionName'));

        // The format for the language is different between OTOBO and CKEditor (see bug#8024)
        // To correct this, we replace "_" with "-" in the language (e.g. zh_CN becomes zh-cn)
        UserLanguage = Core.Config.Get('UserLanguage').replace(/_/, "-");

        if (typeof ClassicEditor === 'undefined') {
            return false;
        }

        // Check if instance is already loaded
        if (isJQueryObject($EditorArea) && $EditorArea.hasClass('HasCKEInstance')) {
            return false;
        }

        if (isJQueryObject($EditorArea) && $EditorArea.length === 1) {
            EditorID = $EditorArea.attr('id');
        }

        if (EditorID === '') {
            Core.Exception.Throw('RichTextEditor: Need exactly one EditorArea!', 'TypeError');
        }

        // Common editor label
        const RichTextLabel = $('label[for="RichText"]');

        //Change to new CKEditor format <br*> tags to Paragraphs
        $($EditorArea).val($($EditorArea).val().replace(/<br[^>]*>/gi,'<p>&nbsp;</p>'));

        //Arrange toolbar items (Plugins load are managed in Layout.pm)
        var Integrations;
        var ToolbarItems = [ 'bold', 'italic', 'underline', 'strikethrough', '|', 'bulletedList', 'numberedList', '|',
                             'insertTable', '|', 'indent', 'outdent',  'alignment', '|',
                             'link', 'undo', 'redo', 'selectAll', '-',
                             'insertImage', 'horizontalLine', 'blockQuote', '|', 'findAndReplace', 'fontColor', 'fontBackgroundColor', 'removeFormat', '|',
                             'sourceEditing', 'specialCharacters', '-',
                             'heading', 'fontFamily', 'fontSize'];

        if ( CheckFormID($EditorArea).length ) {
            Integrations = [ 'upload', 'url' ];
        } else {
            Integrations = [ 'url' ];
        }

        //Load enhanced mode toolbar buttons
        if ( Core.Config.Get('RichText.EnhancedModeAgent') > 0 && !CustomerInterface ||
                Core.Config.Get('RichText.EnhancedModeCustomer') > 0 && CustomerInterface ) {

            var EnhancedModeItems = Core.Config.Get('RichText.EnhancedModeItems');
            ToolbarItems.push('|');

            $.each(EnhancedModeItems, function( index, value ) {
                ToolbarItems.push(value);
            });
        }

        ClassicEditor.create($($EditorArea).get(0), {
            heading: {
                options: [
                    { model: 'paragraph', title: 'Paragraph', class: 'ck-heading_paragraph' },
                    { model: 'heading1', view: 'h1', title: 'Heading 1', class: 'ck-heading_heading1' },
                    { model: 'heading2', view: 'h2', title: 'Heading 2', class: 'ck-heading_heading2' },
                    { model: 'heading3', view: 'h3', title: 'Heading 3', class: 'ck-heading_heading3' },
                    { model: 'heading4', view: 'h4', title: 'Heading 4', class: 'ck-heading_heading4' },
                    { model: 'heading5', view: 'h5', title: 'Heading 5', class: 'ck-heading_heading5' },
                    { model: 'heading6', view: 'h6', title: 'Heading 6', class: 'ck-heading_heading6' },
                ]
            },
            fontSize: {
                options: [
                    'default', 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30
                ],
                supportAllValues: true
            },
            fontFamily: {
                supportAllValues: true
            },
            toolbar: {
                shouldNotGroupWhenFull: true,
                items: ToolbarItems
            },
            plugins: EnabledPlugins,
            language: {
                ui: UserLanguage,
                content: UserLanguage
            },
            image: {
                resizeUnit: 'px',
                insert: {
                    type: 'inline'
                },
                toolbar: ['imageStyle:alignLeft', 'imageStyle:alignCenter', 'imageStyle:alignRight'],
                insert: {
                    // Expose only needed dropdown options
                    integrations: Integrations
                }
            },
            table: {
                tableCellProperties: {
                    defaultProperties: {
                        horizontalAlignment: 'left',
                        verticalAlignment: 'top',
                    }
                }
            },
            simpleUpload: {
                // build URL for image upload
                uploadUrl: Core.Config.Get('Baselink')
                    + 'Action='
                    + Core.Config.Get('RichText.PictureUploadAction', 'PictureUpload')
                    + '&FormID='
                    + CheckFormID($EditorArea).val()
                    + '&' + Core.Config.Get('SessionName')
                    + '=' + Core.Config.Get('SessionID'),

                // Enable the XMLHttpRequest.withCredentials property.
                withCredentials: false,

                // Headers sent along with the XMLHttpRequest to the upload server.
                headers: {}
            }          
        })
            .then(editor => {
                /* Generate ID for current Editor */
                editor.ElementId = EditorID;
                CKEditorInstances[$EditorArea.attr('id')] = editor;

                window.editor = editor;

                /* Set Container size */
                var domEditableElement = $($EditorArea).closest(".RichTextField");

                //Try use RichTextHolder for Customer Interface
                if (!domEditableElement) {
                    domEditableElement = document.querySelector('.RichTextHolder');
                }

                $(domEditableElement).css('max-width', Core.Config.Get('RichText.Width', 620) + 'px');
                $(domEditableElement).css('min-height', Core.Config.Get('RichText.Height', 320) + 'px');

                /* Set editing area size */
                editor.editing.view.change(writer => {
                    writer.setStyle('max-width', Core.Config.Get('RichText.Width', 620) + 'px', editor.editing.view.document.getRoot());
                    writer.setStyle('max-height', Core.Config.Get('RichText.Height', 320) + 'px', editor.editing.view.document.getRoot());
                    writer.setStyle('min-height', Core.Config.Get('RichText.Height', 320) + 'px', editor.editing.view.document.getRoot());
                });

                if (CustomerInterface) {
                    $(domEditableElement).css('max-width', '66%');
                    $(domEditableElement).css('margin', '0 auto');

                    editor.editing.view.document.getRoot('main').placeholder = RichTextLabel[0].innerText;
                    RichTextLabel.hide();

                    /* Set editing area width for Customer */
                    editor.editing.view.change(writer => {
                        writer.setStyle('max-width', '100%', editor.editing.view.document.getRoot());
                    });
                }

                Core.App.Publish('Event.UI.RichTextEditor.InstanceCreated', [editor]);

                //Update validation error tooltip while content is added to the editor
                editor.model.document.on('change:data', () => {
                    if (editor.getData() != "") {
                        $("#" + editor.ElementId).val(editor.getData());
                    }

                    window.clearTimeout(TimeOutRTEOnChange);
                    TimeOutRTEOnChange = window.setTimeout(function () {
                        Core.Form.Validate.ValidateElement($EditorArea);
                        Core.App.Publish('Event.UI.RichTextEditor.ChangeValidationComplete', [editor]);
                    }, 250);
                });

                editor.ui.focusTracker.on('change:isFocused', (evt, name, isFocused) => {
                    if (!isFocused) {
                        $("#" + $EditorArea.attr('id')).val(editor.getData());

                        Core.Form.Validate.ValidateElement($EditorArea);
                        Core.Form.ErrorTooltips.RemoveRTETooltip($EditorArea);
                    }
                });
            })
            .catch(error => {
                console.error(error);
            });

        // mark the editor textarea as linked with an RTE instance to avoid multiple instances
        $EditorArea.addClass('HasCKEInstance');

        //Remove validation for undefined elements on CKEditor (JQuery validate plugin exception)
        $(document).ready(function () {
            $('form').each(function () {
                if ($(this).data('validator')) {
                    $(this).data('validator').settings.ignore = ".ck, .ck-editor__editable, .ck-content";
                    return false;
                }
            });
        });
    };

    /**
     * @name InitAllEditors
     * @memberof Core.UI.RichTextEditor
     * @function
     * @description
     *      This function initializes as a rich text editor every textarea element that containing the RichText class.
     */
    TargetNS.InitAllEditors = function () {

        if (typeof ClassicEditor === 'undefined') {
            return;
        }

        $('textarea.RichText').each(function () {
            TargetNS.InitEditor($(this));
        });
    };

    /**
     * @name Init
     * @memberof Core.UI.RichTextEditor
     * @function
     * @description
     *      This function initializes JS functionality.
     */
    TargetNS.Init = function () {

        if (typeof ClassicEditor === 'undefined' || Core.Config.Get('Action') == 'AdminGenericInterfaceMappingXSLT') {
            return;
        }

        TargetNS.InitAllEditors();
    };

    /**
     * @name GetRTE
     * @memberof Core.UI.RichTextEditor
     * @function
     * @returns {jQueryObject} jQuery object of the corresponsing RTE element.
     * @param {jQueryObject} $EditorArea - The jQuery object of the element that is a rich text editor.
     * @description
     *      Get RTE jQuery element.
     */
    TargetNS.GetRTE = function ($EditorArea) {
        var $RTE;

        if (isJQueryObject($EditorArea)) {
            $RTE = $($EditorArea.attr('id'));
            return ($RTE.length ? $RTE : undefined);
        }
    };

    /**
     * @name UpdateLinkedField
     * @memberof Core.UI.RichTextEditor
     * @function
     * @param {jQueryObject} $EditorArea - The jQuery object of the element that is a rich text editor.
     * @description
     *      This function updates the linked field for a rich text editor.
     */
    TargetNS.UpdateLinkedField = function ($EditorArea) {
        var EditorID = '',
            Data,
            StrippedContent;

        if (isJQueryObject($EditorArea) && $EditorArea.length === 1) {
            EditorID = $EditorArea.attr('id');
        }

        if (EditorID === '') {
            Core.Exception.Throw('RichTextEditor: Need exactly one EditorArea!', 'TypeError');
        }

        Data = window.editor.getData();
        StrippedContent = Data.replace(/\s+|&nbsp;|<\/?\w+[^>]*\/?>/g, '');

        if (StrippedContent.length === 0 && !Data.match(/<img/)) {
            $EditorArea.val('');
        }
        else {
            $EditorArea.val(Data);
        }
    };

    /**
     * @name IsEnabled
     * @memberof Core.UI.RichTextEditor
     * @function
     * @returns {Boolean} True if RTE is enabled, false otherwise
     * @param {jQueryObject} $EditorArea - The jQuery object of the element that is a rich text editor.
     * @description
     *      This function check if a rich text editor is enable in this moment.
     */
    TargetNS.IsEnabled = function ($EditorArea) {
        if (typeof window.editor === 'undefined') {
            return false;
        }

        if (isJQueryObject($EditorArea) && $EditorArea.length && $EditorArea.hasClass('RichText')) {
            return (window.editor ? true : false);
        }
        return false;
    };

    /**
     * @name Focus
     * @memberof Core.UI.RichTextEditor
     * @function
     * @param {jQueryObject} $EditorArea - The jQuery object of the element that is a rich text editor.
     * @description
     *      This function focusses the given RTE.
     */
    TargetNS.Focus = function ($EditorArea) {
        var EditorID = '';

        if (isJQueryObject($EditorArea) && $EditorArea.length === 1) {
            EditorID = $EditorArea.attr('id');
        }

        if (EditorID === '') {
            Core.Exception.Throw('RichTextEditor: Need exactly one EditorArea!', 'TypeError');
        }

        if (typeof ClassicEditor != 'undefined') {
            CKEditorInstances[$EditorArea.attr('id')].focus();
        }
    };

    Core.Init.RegisterNamespace(TargetNS, 'APP_MODULE');

    return TargetNS;
}(Core.UI.RichTextEditor || {}));
