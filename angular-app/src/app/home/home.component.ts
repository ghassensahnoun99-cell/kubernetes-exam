import { Component, OnInit } from '@angular/core';
import { UserService } from '../services/user.service';
import { User } from '../models/User';

@Component({
  selector: 'app-home',
  templateUrl: './home.component.html',
  styleUrls: ['./home.component.css']
})
export class HomeComponent implements OnInit{

  usersList:User[]=[];

  constructor(private userService:UserService){}
  ngOnInit(): void {
    this.getAllUsers()
  }

  getAllUsers(){
      this.userService.getAllUsers().subscribe(res=>{
        res.map(((obj: User)=>{
          this.usersList.push(obj)
        }))
      },
      error=>{
        alert(error);
      })
  }

  addUser(firstname:string,lastname:string){
      this.userService.addUser(firstname,lastname).subscribe(res=>{
        window.location.reload();
    })
  }
  deleteUser(id:string){
    this.userService.deleteUser(id).subscribe(res=>{
      window.location.reload();
    })
  }


}
