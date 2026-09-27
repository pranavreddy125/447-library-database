# **Library Management System**

EECS 447 — Part 2: Domain Modeling and Requirements Engineering

## **1\. Introduction**

### **Project Overview**

The Library Management System is a relational database for a small library. Its purpose is to organize information about library items, clients, memberships, loans, returns, reservations, notifications, and fees. Library staff will use it to maintain records and process circulation activities, while clients can search the catalog, view loan information, and reserve eligible items. The system is intended to improve record accuracy, reduce manual tracking, and support required queries and reports.

### **Scope**

The system will cover books, digital media, magazines, client and membership records, checkouts, returns, due dates, borrowing limits, item restrictions, late fees, reservations, notifications, and library reports. Later phases will produce the ER model, normalized relational schema, PostgreSQL implementation, sample data, and demonstration queries. The project will not include a production interface, integration with outside library systems, or functions unrelated to the stated small-library operations.

### **Glossary**

* Client/Member — A registered library user who can borrow or reserve eligible items.  
* Library Item — A book, digital media item, or magazine managed by the library.  
* Loan — A record of an item being checked out to a client and later returned.  
* Reservation — A client request for an eligible item that is currently unavailable.

## **2\. Stakeholders**

The library database system has several stakeholders who interact with the system directly or have an interest in the information it stores and manages.

### **Library Clients/Members**

Library clients and members are the primary users who benefit from the database. They use library services to search for available books and other materials, borrow and return items, and view information related to their account and borrowing history.

### **Library Staff**

Library staff interact directly with the database during daily library operations. They use the system to register members, manage checkouts and returns, update item information, check availability, and assist members with locating library materials.

### **Database/System Administrator**

The database or system administrator is responsible for maintaining the database system. Their responsibilities include managing database access, maintaining data integrity, performing backups, monitoring system performance, and ensuring that the database remains available and secure.

### **Library Management**

Library management uses information stored in the database to oversee library operations and make decisions. They may use reports and queries to review circulation activity, popular materials, overdue items, membership information, and other statistics related to library usage.

### **Project Development Team**

The project development team is responsible for designing, implementing, testing, and maintaining the library database system. The team uses the project requirements to determine the database structure, relationships, constraints, queries, and other functionality needed to meet the needs of the library and its users.

## **3\. Requirements**

### **Functional Requirements**

#### **Catalog Searching and Retrieval**

* The system shall let clients and staff search the library catalog by title, author, or item type.  
* The system will show each matching item’s title, item type, and availability status in the search results.

#### **Client and Membership Management**

* The system will let authorized staff create and update client records, including names, contact information, membership type, and account status.  
* The system shall prevent clients/members with inactive or restricted accounts from checking out items when applicable.

#### **Item Management**

* The system shall allow authorized staff to add, update, and remove items from the library catalog.  
* The system shall prevent staff from removing an item that is currently checked out or has an active reservation.

#### **Checkouts and Returns**

* The system shall let authorized staff check out eligible items to clients and record the checkout date and time, due date, and client.  
* The system shall let authorized staff record an item’s return date and time and update its availability status.

#### **Borrowing Limits and Restrictions**

* The system shall enforce borrowing limits based on the client’s membership type.  
* The system shall prevent clients/members from checking out library items when they have reached their borrowing limit, have a restriction that prohibits borrowing, or the item has a borrowing restriction, such as a rare book or the latest issue of a magazine.

#### **Late Fees**

* The system shall identify items not returned by their due date and calculate late fees using the library’s rules and the client’s membership type.  
* The system shall keep a record of each client’s late fees.

#### **Reservations**

* The system shall let clients reserve unavailable items and update the reservation status when the item becomes available.  
* The system shall record the client, item, reservation date, and status for each reservation.

#### **Notifications**

* The system shall identify loans due soon, overdue loans, and available reserved items that need a notification.  
* The system shall create notification records for upcoming due dates, overdue loans, and available reservations.

### **Queries and Reports**

The system shall support the following queries and reports:

* Available items: List available library items by genre and item type. Genre filtering applies to books and digital media.  
* Overdue items and fees: List overdue items, their responsible clients, due dates, and calculated late fees.  
* Client activity: Show a client’s borrowing history, unpaid fees, and reservations.  
* Borrowing by membership type: Show the items borrowed most often by each membership type.  
* Monthly borrowing summary: Report the total number of loans and the most popular items for a selected month.

#### **Additional Team-Proposed Queries**

* Pending reservations: List pending reservations and the number of days each has been waiting.  
* Restricted items: List items with borrowing restrictions so staff can identify materials unavailable for checkout.

### **Data Entities and Attributes**

#### **Library Items**

Books, digital media, and magazines owned by the library, whether available or checked out.

Common attributes: Item ID (integer, unique), title (text), item type (text: book, digital media, or magazine), availability status (text), borrowing restricted (boolean).

Books/Digital Media: Author/creator (text), ISBN (text, optional when not applicable), publication year (integer), genre (text).

Magazines: Issue number (text), publication date (date).

#### **Clients**

Clients who use the library’s services.

Attributes: Client ID (integer, unique), first name (text), last name (text), phone number (text), membership type ID (integer), account status (text: active, inactive, or restricted).

#### **Membership Types**

Membership categories, such as regular, student, and senior, that determine borrowing limits and late-fee rates.

Attributes: Membership type ID (integer, unique), name (text), borrowing limit (integer, non-negative), daily late-fee rate (decimal, non-negative).

#### **Loans**

Records of library items checked out to clients.

Attributes: Loan ID (integer, unique), item ID (integer), client ID (integer), checkout timestamp (timestamp), due date (date), return timestamp (timestamp, empty until returned).

#### **Reservations**

Client requests for library items that are currently on loan.

Attributes: Reservation ID (integer, unique), client ID (integer), item ID (integer), reservation date (date), reservation status (text: pending, available, fulfilled, or cancelled).

#### **Notifications**

Notices for upcoming due dates, overdue loans, and available reservations.

Attributes: Notification ID (integer, unique), client ID (integer), related loan ID or reservation ID (integer, as applicable), notification type (text), message (text), creation timestamp (timestamp).

#### **Late Fees**

Late-fee amounts associated with a client’s overdue loan.

Attributes: Fee ID (integer, unique), loan ID (integer), amount owed (decimal, non-negative), amount paid (decimal, non-negative).

#### **Constraints**

* Each client has one membership type, which determines their borrowing limit and late-fee rate.  
* An item may have only one active loan at a time.  
* Borrowing limits and client/item restrictions must be enforced at checkout.  
* Loan, reservation, notification, and fee records must refer to existing related records.  
* The due date and return timestamp cannot precede checkout.  
* Required attributes must be present, except the optional values identified above. ISBN is not the unique identifier for a library item.  
* Reservations and fee totals for a client are obtained from their related records; an item’s last borrowed date is obtained from loan history.

## **4\. Hardware and Software Requirements**

Team members will use a computer with internet access, a web browser, and a code or SQL editor. The database will use PostgreSQL hosted through Supabase, and GitHub will be used to store and manage project files (Supabase was chosen by Pranav because of his prior experience with it, additionally, the free plan offers enough storage for the project). No dedicated local server is required.

## Project Meeting Log

### Meeting: Sep 13, 2026

Time: 11–12pm

Location: Discord/Virtual

Objective: Discuss Part 2, divide the required sections among team members, review the work completed, and establish a plan for completing and reviewing the remaining sections.

Team Members Present: Mo, Pranav, Gabe, Karim, Dani

### Tasks Completed

* Reviewed the project Part 2 requirements.  
* Completed the initial introduction.  
* Divided the remaining requirements document sections among team members.  
* Determined that the stakeholder section will be based on information established in the introduction and project overview.  
* Decided on the next meeting.

### Tasks Allocated

* Mo: Stakeholder section and meeting log.  
* Pranav: Introduction and coordination.  
* Gabe: Requirements section.  
* Daniel: Requirements section.  
* Karim: Requirements section.  
* Karim, Dani, and Gabe will work together on the Functional Requirements, Data Entities, and Hardware/Software Requirements.

Deadline: Remaining sections are expected to be complete by the week of the 20th.

### Follow-Up Action

* Mo will complete the stakeholder section.  
* Karim, Dani, and Gabe will work together to complete the Requirements and Hardware/Software Requirements sections.  
* Mo and Pranav will review the completed section once the initial work is done.  
* Schedule the next meeting for Sunday, Sep 20, 2026 at 5pm.

## Project Meeting Log

### Meeting: Sep 20, 2026

Time: 5–6pm

Location: Discord/Virtual

Objective: Check in on the progress of Part 2, review the current status of every assigned task, and discuss next steps.

Team Members Present: Mo, Pranav, Gabe, Karim, Dani

### Tasks Completed

* No major tasks completed.  
* Team members gave updates on the current progress of their respective tasks.

### Tasks Allocated

* Mo: Stakeholder section and meeting log.  
* Pranav: Introduction and coordination.  
* Gabe: Requirements section.  
* Daniel: Requirements section.  
* Karim: Requirements section.

Deadline: Remaining sections are expected to be complete by midweek.

### Follow-Up Action

* Mo will finish the stakeholder section.  
* Karim, Dani, and Gabe will keep working together on their sections.  
* Pranav will keep coordinating the project.  
* The team will review completed sections once tasks are completed.