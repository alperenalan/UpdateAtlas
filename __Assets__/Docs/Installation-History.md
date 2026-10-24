# Installation and update history

Update Atlas stores a local observation log named `installation-history-v1.json` in its UpdateAtlas
folder under the user's Library Application Support directory.
The first complete scan records a baseline without claiming that existing software was installed at that time.
Later complete scans record a newly detected item, an item seen again after absence, or a changed installed version. A successful
one-item reread after an update can record the version change immediately. The record is independent of update
availability: a newer version offered by a publisher is not an installed update.

The timestamp is when Update Atlas observed the item or version. It is not the time an installer ran, and earlier
installation times cannot be reconstructed. Incomplete and cancelled scans do not modify the log. The main window
shows all events under **Activity → Installation & Update History**; each item's inspector shows that item's events.
The history includes apps, games and other versioned software in the inventory, but excludes containers and virtual
machines. The app does not upload this file. A missing file starts a fresh baseline; an unreadable or unsupported
file is preserved and history writes stop with an in-app warning.
